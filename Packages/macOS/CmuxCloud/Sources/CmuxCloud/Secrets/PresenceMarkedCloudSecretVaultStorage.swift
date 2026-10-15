import Foundation

/// A ``CloudSecretVaultStorage`` that keeps a non-secret file saying whether a vault
/// exists, so a launch can skip the Keychain when there is nothing to read.
///
/// An ad-hoc signed DEV build has no Keychain access group, so its vault lives in the
/// login keychain, whose item is bound to the code signature: every rebuild makes the
/// first read ask for the user's password. The marker is an empty file beside the
/// app's other support files; it holds no name or value. It is written after a save
/// or a read that found a vault, and removed after a delete or a read that found none.
/// Marker writes are best effort: a stale marker only costs one Keychain read.
///
/// ```swift
/// let storage = PresenceMarkedCloudSecretVaultStorage(
///     base: KeychainCloudSecretVaultStorage(service: service),
///     markerURL: supportDirectory.appendingPathComponent("cloud-secrets.present")
/// )
/// ```
public struct PresenceMarkedCloudSecretVaultStorage: CloudSecretVaultStorage {
    public let base: any CloudSecretVaultStorage
    public let markerURL: URL

    public init(base: any CloudSecretVaultStorage, markerURL: URL) {
        self.base = base
        self.markerURL = markerURL
    }

    /// True when the last save or read left a vault behind.
    public var markerExists: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    public func load() throws -> Data? {
        let data = try base.load()
        if data == nil { removeMarker() } else { writeMarker() }
        return data
    }

    public func save(_ data: Data) throws {
        try base.save(data)
        writeMarker()
    }

    public func delete() throws {
        try base.delete()
        removeMarker()
    }

    private func writeMarker() {
        guard !markerExists else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = manager.createFile(atPath: markerURL.path, contents: Data())
    }

    private func removeMarker() {
        guard markerExists else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }
}
