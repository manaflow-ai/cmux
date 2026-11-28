public import Foundation

/// Remembers that the owner removed this Mac from the account's devices, so the app
/// does not register it again after a relaunch. It lives in hostd's state folder
/// (`<directory>/removed`, mode 0600) and holds the account key it applies to
/// (user and team) on its first line and the removed device id on its second:
/// another account, or the person allowing iPhone connections again, clears it.
///
/// The record is checked, never trusted for good: hostd is started with it
/// (`CMUX_MOBILE_RECORDED_REMOVAL`) and asks the service first. A real removal is no
/// longer listed and hostd stays stopped; a record an older hostd wrote for a 4002
/// `silent` close (2026-11-27) is still listed, and hostd clears it and connects.
/// Records from before the id was kept have one line (``legacyValue``).
public struct MobileHostRemovalMarker: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var file: URL { directory.appendingPathComponent("removed", isDirectory: false) }

    /// What hostd is told for a record with no device id (`CMUX_MOBILE_RECORDED_REMOVAL`).
    public static let legacyValue = "legacy"

    private func lines() -> [String]? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The account key the removal applies to, nil when this Mac is not removed.
    public func account() -> String? {
        guard let key = lines()?.first, !key.isEmpty else { return nil }
        return key
    }

    /// The device id that was removed, nil for a record from before it was kept.
    public func deviceID() -> String? {
        guard let lines = lines(), lines.count > 1 else { return nil }
        let id = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// `CMUX_MOBILE_RECORDED_REMOVAL` for this record: its device id, or ``legacyValue``.
    public func recordedValue() -> String { deviceID() ?? Self.legacyValue }

    /// Records the removal of `deviceID` for `account` and forgets this Mac's device id, so
    /// allowing connections again registers a new device.
    public func record(account: String, deviceID: String?, identity: MobileHostDeviceIdentity) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let text = deviceID.map { "\(account)\n\($0)" } ?? account
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        identity.forget()
    }

    /// The person allowed connections again (or another account signed in).
    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
