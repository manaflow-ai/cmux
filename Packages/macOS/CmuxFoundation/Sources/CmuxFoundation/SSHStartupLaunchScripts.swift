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
    private var unlaunched: [URL] = []

    /// Creates an owner that writes launchers into `directory`.
    ///
    /// - Parameters:
    ///   - directory: Where launchers are written, normally the user's temporary directory.
    ///   - fileManager: The file manager used to write and remove launchers.
    public init(directory: URL, fileManager: FileManager = FileManager()) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Writes an executable, owner-only launcher that runs `scriptBody` with `/bin/sh`.
    ///
    /// - Parameters:
    ///   - scriptBody: The shell script, without a shebang line.
    ///   - remoteRelayPort: The relay port, recorded in the file name for diagnostics.
    /// - Returns: The launcher's file URL.
    /// - Throws: An error when the launcher cannot be written.
    public func write(scriptBody: String, remoteRelayPort: Int) throws -> URL {
        let scriptURL = directory.appendingPathComponent(
            "cmux-ssh-startup-\(remoteRelayPort)-\(UUID().uuidString.lowercased()).sh"
        )
        let script = "#!/bin/sh\n\(scriptBody)\n"
        // Track before writing so a failed permission change still removes the file.
        unlaunched.append(scriptURL)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
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
