import AppKit
import CmuxSimulator
import Darwin
import Foundation

/// Runs the isolated Simulator renderer on framed stdin/stdout pipes.
///
/// The cmux executable calls this before normal app startup when launched with
/// ``SimulatorWorkerClient/workerModeArgument``. Private Simulator frameworks,
/// IOSurfaces, HID clients, and accessibility objects stay in this process.
/// EOF or a shutdown command releases held input and exits the worker.
///
/// - Parameters:
///   - readFD: Descriptor receiving ``SimulatorWorkerInbound`` messages.
///   - writeFD: Descriptor sending ``SimulatorWorkerOutbound`` messages.
/// - Returns: This function never returns.
public func runSimulatorWorker(
    readFD: Int32 = STDIN_FILENO,
    writeFD: Int32 = STDOUT_FILENO
) -> Never {
    guard SimulatorWorkerProcessGroup().isolateCurrentProcess() else {
        _exit(SimulatorWorkerProcessGroup.isolationFailureExitStatus)
    }
    signal(SIGPIPE, SIG_IGN)
    let channel = SimulatorLengthPrefixedMessageChannel(readFD: readFD, writeFD: writeFD)
    let queue = SimulatorBoundedMessageQueue<SimulatorWorkerInbound>(
        limit: SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount
    )
    let gracefulExitAcknowledgement = DispatchSemaphore(value: 0)

    // A blocking read is the descriptor's wake-up primitive. It is confined
    // to this reader thread and yields into one ordered main-actor consumer.
    let reader = Thread {
        let decoder = JSONDecoder()
        while let data = channel.receiveMessage() {
            guard let message = try? decoder.decode(SimulatorWorkerInbound.self, from: data) else {
                continue
            }
            switch queue.yield(message) {
            case .enqueued:
                continue
            case .overflow:
                // The main actor may be blocked in private Simulator code. Exit
                // immediately so the host invalidates and restarts this generation.
                _exit(SimulatorLengthPrefixedMessageChannel.protocolQueueOverflowExitStatus)
            case .terminated:
                return
            }
        }
        queue.finish()
        // EOF is the host-lifetime signal. Give ordered main-actor cleanup one
        // bounded chance, then exit independently if private Simulator code has
        // blocked that actor.
        if gracefulExitAcknowledgement.wait(timeout: .now() + 1) == .timedOut {
            _exit(0)
        }
    }
    reader.name = "cmux-simulator-worker-reader"
    reader.stackSize = 1 << 20
    reader.start()

    MainActor.assumeIsolated {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let coordinator = SimulatorWorkerCoordinator(channel: channel)
        Task { @MainActor in
            for await message in queue.stream {
                guard await coordinator.handle(message) else {
                    gracefulExitAcknowledgement.signal()
                    exit(0)
                }
            }
            coordinator.prepareForProcessExit()
            gracefulExitAcknowledgement.signal()
            exit(0)
        }
        application.run()
    }
    exit(0)
}
