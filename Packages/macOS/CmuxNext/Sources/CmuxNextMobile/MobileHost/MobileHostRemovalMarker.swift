public import Foundation

/// Remembers that the owner removed this Mac from the account's devices, so the app
/// does not register it again after a relaunch. It lives in hostd's state folder
/// (`<directory>/removed`, mode 0600) and holds the account key it applies to
/// (user and team): another account, or the person allowing iPhone connections
/// again, clears it.
public struct MobileHostRemovalMarker: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var file: URL { directory.appendingPathComponent("removed", isDirectory: false) }

    /// The account key the removal applies to, nil when this Mac is not removed.
    public func account() -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .newlines)
        return key.isEmpty ? nil : key
    }

    /// Records the removal for `account` and forgets this Mac's device id, so allowing
    /// connections again registers a new device.
    public func record(account: String, identity: MobileHostDeviceIdentity) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(account.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        identity.forget()
    }

    /// The person allowed connections again (or another account signed in).
    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
