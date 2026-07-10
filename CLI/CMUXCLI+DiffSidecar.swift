import Foundation

/// Process selection and launch for the portable diff-viewer backend.
extension CMUXCLI {
    func startDiffViewerHTTPServer(rootDirectory: URL, runtime: URL? = nil) throws -> URL {
        guard let cmuxExecutableURL = diffViewerExecutableURL(for: runtime),
              let executableURL = diffViewerServerExecutableURL(for: runtime) else {
            throw CLIError(message: "Failed to resolve cmux executable for diff viewer server")
        }

        let process = Process()
        process.executableURL = executableURL
        if executableURL == cmuxExecutableURL {
            process.arguments = ["diff-viewer-server", "--root", rootDirectory.path]
        } else {
            process.arguments = [
                "serve",
                "--root", rootDirectory.path,
                "--cmux", cmuxExecutableURL.path,
            ]
        }
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = nullInput
        }
        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardError = nullOutput
        }

        do {
            try process.run()
        } catch {
            throw CLIError(message: "Failed to start diff viewer server: \(error.localizedDescription)")
        }

        let port = try readDiffViewerHTTPServerPort(
            from: stdoutPipe.fileHandleForReading,
            process: process
        )
        guard diffViewerHTTPServerIsReachable(port: port) else {
            process.terminate()
            throw CLIError(message: "Diff viewer server did not become reachable")
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw CLIError(message: "Failed to build diff viewer server URL")
        }
        return url
    }

    func diffViewerServerExecutableURL(for runtime: URL?) -> URL? {
        guard let cmuxExecutable = diffViewerExecutableURL(for: runtime) else { return nil }
        let sidecar = cmuxExecutable.deletingLastPathComponent()
            .appendingPathComponent("cmux-diff-sidecar", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: sidecar.path) {
            return sidecar.standardizedFileURL.resolvingSymlinksInPath()
        }
        return cmuxExecutable
    }

    func diffViewerUsesTypedSidecar(runtime: URL?) -> Bool {
        guard let selected = diffViewerServerExecutableURL(for: runtime),
              let legacy = diffViewerExecutableURL(for: runtime) else {
            return false
        }
        return selected.standardizedFileURL.resolvingSymlinksInPath().path
            != legacy.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
