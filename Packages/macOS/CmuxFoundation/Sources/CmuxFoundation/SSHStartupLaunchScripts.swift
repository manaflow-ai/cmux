internal import Darwin
public import Foundation

/// One-shot launcher scripts that start an SSH terminal, owned by the command
/// that writes them until a terminal takes them over.
///
/// A launcher can carry a short-lived credential, so it lives in a file rather
/// than in the terminal's startup command, which the socket API can report.
/// A launcher deletes itself when it runs; one whose terminal never starts
/// must be removed by its owner.
///
/// ```swift
/// let launchScripts = SSHStartupLaunchScripts(directory: FileManager.default.temporaryDirectory)
/// defer { launchScripts.removeUnlaunched() }
/// let script = try launchScripts.write(scriptBody: body, remoteRelayPort: 0)
/// // ... create the terminal that runs `script` ...
/// launchScripts.handOff()
/// ```
public final class SSHStartupLaunchScripts {
    private let directory: URL
    private let fileManager: FileManager
    private let scriptName: (Int) -> String
    private var unlaunched: [URL] = []

    /// Creates an owner that writes launchers into `directory`.
    ///
    /// - Parameters:
    ///   - directory: Where launchers are written, normally the user's temporary directory.
    ///   - fileManager: The file manager used to remove launchers.
    public convenience init(directory: URL, fileManager: FileManager = FileManager()) {
        self.init(directory: directory, fileManager: fileManager) { remoteRelayPort in
            "cmux-ssh-startup-\(remoteRelayPort)-\(UUID().uuidString.lowercased()).sh"
        }
    }

    /// Creates an owner with a fixed launcher naming rule, so tests can
    /// place a file where the next launcher would go.
    init(directory: URL, fileManager: FileManager, scriptName: @escaping (Int) -> String) {
        self.directory = directory
        self.fileManager = fileManager
        self.scriptName = scriptName
    }

    /// Writes an executable, owner-only launcher that runs `scriptBody` with `/bin/sh`.
    ///
    /// - Parameters:
    ///   - scriptBody: The shell script, without a shebang line.
    ///   - remoteRelayPort: The relay port, recorded in the file name for diagnostics.
    /// - Returns: The launcher's file URL.
    /// - Throws: An error when the launcher cannot be written.
    public func write(scriptBody: String, remoteRelayPort: Int) throws -> URL {
        let scriptURL = directory.appendingPathComponent(scriptName(remoteRelayPort))
        let script = Array("#!/bin/sh\n\(scriptBody)\n".utf8)
        // Create the file owner-only in one step: a create-then-chmod writer
        // leaves the credential readable under the umask until the chmod.
        // O_EXCL and O_NOFOLLOW refuse any file or link already at the path.
        let fd = open(
            scriptURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o700)
        )
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        // Track before writing so a failed write still removes the file. A
        // failed open created nothing, so a file already there is left alone.
        unlaunched.append(scriptURL)
        // The umask can only clear bits; restore the executable bit it may
        // have removed without ever widening access beyond the owner.
        guard fchmod(fd, mode_t(0o700)) == 0 else { throw Self.posixError() }
        try script.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                offset += written
            }
        }
        return scriptURL
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Paths of launchers written but not yet handed off to a terminal.
    public var unlaunchedPaths: [String] {
        unlaunched.map(\.path)
    }

    /// Records that a terminal now runs every launcher written so far.
    ///
    /// Each launcher deletes itself when it runs, so ``removeUnlaunched()``
    /// leaves handed-off launchers in place.
    public func handOff() {
        unlaunched.removeAll()
    }

    /// Removes every launcher that was not handed off to a terminal.
    ///
    /// Call it on every exit path of the command that wrote the launchers,
    /// typically from a `defer`.
    public func removeUnlaunched() {
        for scriptURL in unlaunched {
            try? fileManager.removeItem(at: scriptURL)
        }
        unlaunched.removeAll()
    }
}
