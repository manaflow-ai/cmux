import Foundation

nonisolated public enum CmxDesktopDaemonError: Error, Equatable, LocalizedError {
    case socketReadyTimeout(String)
    case desktopSessionImportFailed(status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .socketReadyTimeout(let path):
            "Timed out waiting for cmx native socket at \(path)."
        case .desktopSessionImportFailed(let status, let output):
            "cmx desktop session import failed with status \(status): \(output)"
        }
    }
}

public actor CmxDesktopDaemon {
    public let executableURL: URL
    public let paths: CmxDesktopRuntimePaths
    private var process: Process?

    public init(executableURL: URL, paths: CmxDesktopRuntimePaths) {
        self.executableURL = executableURL
        self.paths = paths
    }

    public func start(
        importDesktopSessionURL: URL? = nil,
        environment: [String: String]? = nil
    ) throws {
        if process?.isRunning == true {
            return
        }

        try FileManager.default.createDirectory(
            at: paths.stateDirectory,
            withIntermediateDirectories: true
        )

        let nativeSocketURL = URL(fileURLWithPath: paths.nativeSocketPath)
        try FileManager.default.createDirectory(
            at: nativeSocketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let compatibilitySocketURL = URL(fileURLWithPath: paths.compatibilitySocketPath)
        try FileManager.default.createDirectory(
            at: compatibilitySocketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try importDesktopSessionIfNeeded(sourceURL: importDesktopSessionURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--socket",
            paths.nativeSocketPath,
            "--state-dir",
            paths.stateDirectory.path,
            "server",
            "--compat-socket",
            paths.compatibilitySocketPath,
        ]
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        var processEnvironment = environment ?? ProcessInfo.processInfo.environment
        processEnvironment["CMX_EXIT_WHEN_PARENT_PID_EXITS"] = "\(ProcessInfo.processInfo.processIdentifier)"
        processEnvironment["CMUX_SOCKET_PATH"] = paths.compatibilitySocketPath
        let bundledCLIPath = processEnvironment["CMUX_BUNDLED_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if bundledCLIPath?.isEmpty != false {
            let bundledCLIURL = executableURL.deletingLastPathComponent().appendingPathComponent("cmux")
            if FileManager.default.isExecutableFile(atPath: bundledCLIURL.path) {
                processEnvironment["CMUX_BUNDLED_CLI_PATH"] = bundledCLIURL.path
            }
        }
        process.environment = processEnvironment
        try process.run()
        self.process = process
    }

    private func importDesktopSessionIfNeeded(sourceURL: URL?) throws {
        guard let sourceURL,
              Self.shouldImportDesktopSession(
                sourceURL: sourceURL,
                stateDirectory: paths.stateDirectory
              ) else {
            return
        }

        let importProcess = Process()
        importProcess.executableURL = executableURL
        importProcess.arguments = [
            "--state-dir",
            paths.stateDirectory.path,
            "import-desktop-session",
            "--source",
            sourceURL.path,
        ]

        let outputPipe = Pipe()
        importProcess.standardOutput = outputPipe
        importProcess.standardError = outputPipe
        importProcess.standardInput = nil
        try importProcess.run()
        importProcess.waitUntilExit()

        guard importProcess.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CmxDesktopDaemonError.desktopSessionImportFailed(
                status: importProcess.terminationStatus,
                output: output
            )
        }
    }

    nonisolated static func shouldImportDesktopSession(
        sourceURL: URL?,
        stateDirectory: URL
    ) -> Bool {
        guard let sourceURL else {
            return false
        }

        let markerURL = stateDirectory.appendingPathComponent("desktop-session-import.json")
        var markerIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: markerURL.path, isDirectory: &markerIsDirectory),
           !markerIsDirectory.boolValue {
            return false
        }

        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory),
              !sourceIsDirectory.boolValue else {
            return false
        }

        return true
    }

    public func waitUntilReady(timeoutNanoseconds: UInt64 = 2_000_000_000) async throws {
        let startedAt = Date()
        let timeoutSeconds = TimeInterval(timeoutNanoseconds) / 1_000_000_000
        while !Task.isCancelled {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: paths.nativeSocketPath, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return
            }

            if Date().timeIntervalSince(startedAt) >= timeoutSeconds {
                throw CmxDesktopDaemonError.socketReadyTimeout(paths.nativeSocketPath)
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw CancellationError()
    }

    public func makeConnection() -> CmxConnection {
        CmxConnection(transport: CmxUnixSocketTransport(path: paths.nativeSocketPath))
    }

    public func stop() async {
        guard let process else {
            return
        }
        _ = await requestGracefulShutdown()
        for _ in 0..<20 {
            if !process.isRunning {
                self.process = nil
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        process.terminate()
        self.process = nil
    }

    private func requestGracefulShutdown() async -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--socket",
            paths.nativeSocketPath,
            "--state-dir",
            paths.stateDirectory.path,
            "close-server",
        ]
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [process] shutdownProcess in
                process.terminationHandler = nil
                continuation.resume(returning: shutdownProcess.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }
}
