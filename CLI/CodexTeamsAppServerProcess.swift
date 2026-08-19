import Darwin
import Foundation

/// Owns the app-server process launched for one `cmux codex-teams` session.
///
/// The lifetime handle is deliberately separate from the process object. The
/// app-server is often a Node launcher whose native child can outlive the
/// launcher when the launcher receives a fatal signal, so the second commit in
/// this change replaces the direct `Process` launch with a process-group
/// supervisor while keeping this ownership seam stable.
final class CodexTeamsAppServerProcess {
    private let process: Process
    private let lifetimePipe: Pipe
    private var didCloseLifetime = false

    init(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        logURL: URL?
    ) throws {
        let process = Process()
        if executablePath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executablePath] + arguments
        }
        process.currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        process.environment = environment

        let lifetimePipe = Pipe()
        process.standardInput = lifetimePipe.fileHandleForReading
        if let logURL {
            let descriptor = Darwin.open(
                logURL.path,
                O_WRONLY | O_CREAT | O_TRUNC | O_APPEND,
                S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
            )
            guard descriptor >= 0 else {
                throw NSError(
                    domain: "CodexTeamsAppServerProcess",
                    code: Int(errno),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Failed to open Codex Teams log "
                            + logURL.path
                            + ": "
                            + String(cString: strerror(errno))
                    ]
                )
            }
            let logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            process.standardOutput = logHandle
            process.standardError = logHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        try? lifetimePipe.fileHandleForReading.close()
        self.process = process
        self.lifetimePipe = lifetimePipe
    }

    var processIdentifier: pid_t {
        process.processIdentifier
    }

    var isRunning: Bool {
        process.isRunning
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    /// Closes the parent-owned lifetime signal without otherwise touching the
    /// child. This is the boundary exercised when the launching CLI dies.
    func closeParentLifetimeForTesting() {
        closeParentLifetime()
    }

    func terminate() {
        closeParentLifetime()
        guard process.isRunning else { return }
        process.terminate()
    }

    func waitUntilExit() {
        process.waitUntilExit()
    }

    deinit {
        terminate()
    }

    private func closeParentLifetime() {
        guard !didCloseLifetime else { return }
        didCloseLifetime = true
        try? lifetimePipe.fileHandleForWriting.close()
    }
}
