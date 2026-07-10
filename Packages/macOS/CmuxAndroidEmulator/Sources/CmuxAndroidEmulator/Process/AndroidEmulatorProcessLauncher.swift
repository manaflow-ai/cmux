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
        Self.loopbackPortIsAvailable(consolePort) && Self.loopbackPortIsAvailable(consolePort + 1)
    }

    /// Starts the installed emulator with `-avd` and `-port`, without hiding its vendor window.
    public func launch(
        executableURL: URL,
        avdName: String,
        sdkRootURL: URL,
        consolePort: Int
    ) async throws -> UUID {
        let process = Process()
        let processID = UUID()
        process.executableURL = executableURL
        process.arguments = ["-avd", avdName, "-port", String(consolePort)]
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
    public func terminate(processID: UUID) {
        guard let process = processes.removeValue(forKey: processID), process.isRunning else { return }
        process.terminate()
    }

    private func removeProcess(_ processID: UUID) {
        processes.removeValue(forKey: processID)
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
