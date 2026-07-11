public import Foundation
import Darwin

/// Production launcher for vendor Android Emulator windows.
public actor AndroidEmulatorProcessLauncher: AndroidEmulatorProcessLaunching {
    private let baseEnvironment: [String: String]
    private var processes: [UUID: Process] = [:]

    /// Creates a launcher with the environment inherited by spawned emulators.
    ///
    /// - Parameter baseEnvironment: The environment copied into vendor processes.
    public init(baseEnvironment: [String: String]) {
        self.baseEnvironment = baseEnvironment
    }

    /// Implements ``AndroidEmulatorProcessLaunching/consolePortPairIsAvailable(_:)``.
    public func consolePortPairIsAvailable(_ consolePort: Int) -> Bool {
        Self.loopbackPortIsAvailable(consolePort)
            && Self.loopbackPortIsAvailable(consolePort + 1)
            && Self.loopbackPortIsAvailable(Self.grpcPort(consolePort: consolePort))
    }

    /// Starts the installed emulator headlessly with an authenticated local gRPC endpoint.
    public func launch(
        executableURL: URL,
        avdName: String,
        sdkRootURL: URL,
        consolePort: Int
    ) async throws -> UUID {
        let process = Process()
        let processID = UUID()
        process.executableURL = executableURL
        process.arguments = Self.launchArguments(avdName: avdName, consolePort: consolePort)
        process.currentDirectoryURL = sdkRootURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var environment = baseEnvironment
        environment["ANDROID_HOME"] = sdkRootURL.path
        environment["ANDROID_SDK_ROOT"] = sdkRootURL.path
        process.environment = environment
        process.terminationHandler = { [weak self] _ in
            Task { await self?.removeProcess(processID) }
        }

        processes[processID] = process
        do {
            try process.run()
        } catch {
            processes.removeValue(forKey: processID)
            throw AndroidEmulatorError.launchFailed(detail: String(describing: error))
        }
        return processID
    }

    /// Implements ``AndroidEmulatorProcessLaunching/terminate(processID:)``.
    public func terminate(processID: UUID) async {
        guard let process = processes[processID], process.isRunning else {
            processes.removeValue(forKey: processID)
            return
        }
        process.terminate()
        if await waitForExit(process, timeout: .seconds(2)) {
            processes.removeValue(forKey: processID)
            return
        }

        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(process, timeout: .seconds(2))
        processes.removeValue(forKey: processID)
    }

    private func removeProcess(_ processID: UUID) {
        processes.removeValue(forKey: processID)
    }

    private func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(50))
        }
        return !process.isRunning
    }

    static func launchArguments(avdName: String, consolePort: Int) -> [String] {
        [
            "-avd", avdName,
            "-port", String(consolePort),
            "-qt-hide-window",
            "-grpc", String(grpcPort(consolePort: consolePort)),
            "-grpc-use-token",
        ]
    }

    static func grpcPort(consolePort: Int) -> Int {
        consolePort + 3_000
    }

    // Darwin bind is the only atomic OS check for whether the emulator can claim a TCP port.
    private static func loopbackPortIsAvailable(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
