import CmuxControlSocket
import CmuxSettings
import Darwin
import Foundation

extension TerminalController {
    /// Removes runtime discovery state while the listener still owns its path lock.
    ///
    /// ``SocketControlServer`` invokes this callback after closing/unlinking its
    /// listener and before releasing the lock. That lock-owned seam prevents a
    /// replacement listener from publishing a marker between validation and removal.
    func cleanupStoppedSocketState(_ socketPath: String) {
        guard !transport.pathAcceptsConnections(socketPath) else {
            return
        }
        socketPathMarkerStore.clearIfMatching(socketPath)
        clearReloadCLIPathIfMatching(environment: ProcessInfo.processInfo.environment)
    }

    /// Clears the ambient reload pointer only when it still names this app's CLI.
    private func clearReloadCLIPathIfMatching(environment: [String: String]) {
        let pointerPath = "/tmp/cmux-last-cli-path"
        // Reload publication uses this same persistent sibling lock. If another
        // tag is publishing, leave its pointer alone; that reload also performs
        // the stale cleanup required by the exiting instance.
        guard case .acquired(let pointerLockFD, _) = transport.acquireSocketPathLock(
            for: pointerPath
        ) else {
            return
        }
        defer { transport.releaseSocketPathLock(pointerLockFD) }

        var before = stat()
        guard lstat(pointerPath, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_uid == getuid(),
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= off_t(SocketPathMarkerStore.maximumMarkerBytes),
              let pointerContents = boundedDiscoveryFileContents(at: pointerPath)
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
              after.st_size >= 0,
              after.st_size <= off_t(SocketPathMarkerStore.maximumMarkerBytes),
              let currentContents = boundedDiscoveryFileContents(at: pointerPath),
              SocketControlSettings.pathsMatch(
                  currentContents.trimmingCharacters(in: .whitespacesAndNewlines),
                  pointer
              )
        else {
            return
        }
        try? FileManager.default.removeItem(atPath: pointerPath)
    }

    /// Reads one short discovery pointer without accepting an unbounded file.
    private func boundedDiscoveryFileContents(at path: String) -> String? {
        guard let handle = try? FileHandle(
            forReadingFrom: URL(fileURLWithPath: path, isDirectory: false)
        ) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(
            upToCount: SocketPathMarkerStore.maximumMarkerBytes + 1
        ),
            data.count <= SocketPathMarkerStore.maximumMarkerBytes
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
