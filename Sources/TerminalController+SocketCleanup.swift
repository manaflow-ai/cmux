import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation

extension TerminalController {
    /// Removes only runtime discovery state proven to belong to the stopped listener.
    ///
    /// The transport lock and connect probe are the authority. Marker and reload
    /// pointer files are never removed solely because they are old.
    private func cleanupStoppedSocketState(_ socketPath: String) {
        guard !transport.pathAcceptsConnections(socketPath) else {
            return
        }
        guard transport.removeSocketPathLockIfAvailable(for: socketPath) else {
            return
        }
        guard !transport.pathAcceptsConnections(socketPath) else {
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier
        let environment = ProcessInfo.processInfo.environment
        SocketControlSettings.clearLastSocketPathIfMatching(
            socketPath,
            bundleIdentifier: bundleIdentifier,
            environment: environment
        )
        clearReloadCLIPathIfMatching(environment: environment)
    }

    /// Clears the ambient reload pointer only when it still names this app's CLI.
    private func clearReloadCLIPathIfMatching(environment: [String: String]) {
        let pointerPath = "/tmp/cmux-last-cli-path"
        var before = stat()
        guard lstat(pointerPath, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == getuid(),
              before.st_nlink == 1,
              let pointerContents = try? String(contentsOfFile: pointerPath, encoding: .utf8)
        else {
            return
        }
        let pointer = pointerContents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pointer.isEmpty else { return }

        var ownedCLIPaths: [String] = []
        if let bundledPath = environment["CMUX_BUNDLED_CLI_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bundledPath.isEmpty {
            ownedCLIPaths.append(bundledPath)
        }
        let bundlePath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .path
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !bundlePath.isEmpty {
            ownedCLIPaths.append(bundlePath)
        }
        guard ownedCLIPaths.contains(where: { SocketControlSettings.pathsMatch($0, pointer) }) else {
            return
        }

        var after = stat()
        guard lstat(pointerPath, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              let currentContents = try? String(contentsOfFile: pointerPath, encoding: .utf8),
              SocketControlSettings.pathsMatch(
                  currentContents.trimmingCharacters(in: .whitespacesAndNewlines),
                  pointer
              )
        else {
            return
        }
        try? FileManager.default.removeItem(atPath: pointerPath)
    }
}
