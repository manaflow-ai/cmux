import Foundation

struct SimulatorProcessWorkerLauncher: SimulatorWorkerLaunching {
    private let terminationObservationTimeout: TimeInterval
    private let terminationGrace: Duration
    private let writeDeadline: Duration
    private let sleeper: any SimulatorWorkerSleeping

    init(
        terminationObservationTimeout: TimeInterval = 1,
        terminationGrace: Duration = .seconds(1),
        writeDeadline: Duration = .seconds(1),
        sleeper: any SimulatorWorkerSleeping = ContinuousSimulatorWorkerSleeper()
    ) {
        self.terminationObservationTimeout = max(0, terminationObservationTimeout)
        self.terminationGrace = terminationGrace
        self.writeDeadline = writeDeadline
        self.sleeper = sleeper
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> SimulatorWorkerConnection {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = Self.workerEnvironment(
            inherited: ProcessInfo.processInfo.environment,
            additional: environment
        )

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout

        let processBox = SimulatorWorkerProcessBox(
            process: process,
            stdin: stdin,
            stdout: stdout,
            terminationObservationTimeout: terminationObservationTimeout,
            terminationGrace: terminationGrace,
            sleeper: sleeper
        )
        let channel = SimulatorLengthPrefixedMessageChannel(
            readFD: stdout.fileHandleForReading.fileDescriptor,
            writeFD: stdin.fileHandleForWriting.fileDescriptor,
            nonblockingWrites: true,
            writeDeadline: writeDeadline,
            writeFailureHandler: { [weak processBox] in
                processBox?.closeInput()
                processBox?.terminate()
            }
        )
        let queue = SimulatorBoundedMessageQueue<Data>(
            limit: SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount
        )

        processBox.installTerminationHandler()
        do {
            try process.run()
        } catch {
            channel.stopWriting()
            processBox.launchFailed()
            queue.finish()
            throw error
        }
        processBox.didLaunch(processIdentifier: process.processIdentifier)
        // Close the parent copies of the child-only ends. Keeping stdout's
        // write end open here would hide worker EOF after a crash.
        try? stdout.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()

        let reader = Thread { [weak processBox] in
            while let data = channel.receiveMessage() {
                switch queue.yield(data) {
                case .enqueued:
                    continue
                case .overflow:
                    processBox?.failProtocolQueueOverflow()
                    queue.finish()
                    return
                case .terminated:
                    return
                }
            }
            if processBox?.waitForTerminationAfterOutputEOF() == false {
                processBox?.terminate()
            }
            queue.finish()
        }
        reader.name = "cmux-simulator-worker-reader"
        reader.stackSize = 1 << 20
        reader.start()

        return SimulatorWorkerConnection(
            processIdentifier: process.processIdentifier,
            messages: queue.stream,
            send: { data in try channel.sendMessage(data) },
            closeInput: {
                channel.finishWriting {
                    processBox.closeInput()
                }
            },
            terminate: {
                channel.stopWriting()
                processBox.terminate()
            },
            terminalFailure: { processBox.terminalFailure() }
        )
    }

    static func workerEnvironment(
        inherited: [String: String],
        additional: [String: String]
    ) -> [String: String] {
        let allowedKeys = [
            "DEVELOPER_DIR", "DYLD_FRAMEWORK_PATH", "HOME", "LANG", "LC_ALL",
            "LC_CTYPE", "PATH", "SDKROOT", "TMPDIR", "XCODE_DEVELOPER_DIR_PATH",
        ]
        let workerEnvironment = Dictionary(uniqueKeysWithValues: allowedKeys.compactMap { key in
            inherited[key].map { (key, $0) }
        })
        return workerEnvironment.merging(additional) { _, replacement in replacement }
    }
}
