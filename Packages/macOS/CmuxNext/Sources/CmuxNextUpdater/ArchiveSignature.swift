import CmuxNextCompat
public import Foundation

/// The EdDSA signature Sparkle checks before it installs an update, for a build a Switch downloads
/// itself (``BuildSwitchDownload``). The feed's item carries it while the build is on the feed; once
/// the feed drops the build (it keeps two), `<dmg>.signature.json` beside the DMG carries the same
/// signature (scripts/ci/publish-nightly-next-r2.py `signature`). Either way the key is this app's
/// own `SUPublicEDKey`, so a host that serves other bytes, or a signature file that names other
/// bytes, fails the check: the signature file needs no trust of its own.
nonisolated public struct ArchiveSignature: Sendable, Equatable, Decodable {
    /// `sparkle:edSignature`: base64 Ed25519 over the archive's bytes.
    public var edSignature: String
    /// The enclosure's `length`; nil checks no length.
    public var length: Int?

    public init(edSignature: String, length: Int? = nil) {
        self.edSignature = edSignature
        self.length = length
    }

    /// Where the publisher keeps `archive`'s signature: the same name plus `.signature.json`.
    static func sidecar(for archive: URL) -> URL? {
        archive.scheme == "https" ? URL(string: archive.absoluteString + ".signature.json") : nil
    }

    /// The signature published beside `archive`, else nil (a build published before the file existed).
    static func published(for archive: URL,
                          fetch: @Sendable (URL) async -> Data? = PulledBuildWatch.download) async -> ArchiveSignature? {
        guard let url = sidecar(for: archive), let data = await fetch(url) else { return nil }
        return try? JSONDecoder().decode(ArchiveSignature.self, from: data)
    }

    /// Nil when `file` holds the archive this signs under `publicKey` (`SUPublicEDKey`, raw base64),
    /// else why not.
    func failure(checking file: URL, publicKey: String?) -> String? {
        guard let publicKey, !publicKey.isEmpty, !publicKey.hasPrefix("$(") else { return "this app has no update signing key" }
        guard let data = try? Data(blockingContentsOf: file, options: .alwaysMapped) else { return "could not read the download" }
        if let length, data.count != length { return "the download is \(data.count) bytes, its feed item says \(length)" }
        return ContentSignature.verify(data, signature: edSignature, publicKey: publicKey)
            ? nil : "the download's EdDSA signature does not check"
    }
}
