import CryptoKit
public import Foundation

/// One web update channel's pointer (plans/cmux-next/web-ota.md): the web bundle archive the
/// channel serves now. CI writes it with scripts/cmux-next/web-ota-pointer.py as an envelope
/// around exact payload bytes; ``verified(_:keys:channel:)`` checks an ed25519 signature by a
/// trusted key (``WebUpdateKeys``) before it reads any payload field.
nonisolated public struct WebUpdatePointer: Sendable, Equatable, Codable {
    public var channel: String
    /// The bundles' source key (web-bundle-key.py --source); also the folder an update installs in.
    public var key: String
    /// `web-bundles-<sha256>.tar.gz` under `cmux-next-web/<key>/`.
    public var archive: String
    public var sha256: String
    public var size: Int
    /// The digest of the unpacked tree (web-bundle-key.py --outputs, ``WebUpdateTree``).
    public var outputs: String
    /// The native interface the bundles need (webviews/src/web-abi.json).
    public var abi: Int
    public var commit: String
    /// When ``commit`` was made, unix seconds.
    public var committedAt: Int
    public var publishedAt: Int

    nonisolated enum CodingKeys: String, CodingKey {
        case channel, key, archive, sha256, size, outputs, abi, commit
        case committedAt = "committed_at", publishedAt = "published_at"
    }

    public init(channel: String, key: String, archive: String, sha256: String, size: Int, outputs: String, abi: Int,
                commit: String, committedAt: Int, publishedAt: Int) {
        self.channel = channel
        self.key = key
        self.archive = archive
        self.sha256 = sha256
        self.size = size
        self.outputs = outputs
        self.abi = abi
        self.commit = commit
        self.committedAt = committedAt
        self.publishedAt = publishedAt
    }

    /// The largest archive the app downloads.
    public static let maximumSize = 200 << 20

    /// The pointer `data` (an envelope) holds when a trusted key signed it and it is well formed
    /// for `channel`.
    public static func verified(_ data: Data, keys: WebUpdateKeys, channel: String) throws(WebUpdateRefusal) -> WebUpdatePointer {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.schema == 1,
              let payload = Data(base64Encoded: envelope.payload)
        else { throw .malformed("not a pointer envelope") }
        let signed = envelope.signatures.contains { signature in
            guard let key = keys.keys[signature.keyID], let bytes = Data(base64Encoded: signature.sig) else { return false }
            return key.isValidSignature(bytes, for: payload)
        }
        guard signed else { throw .unsigned }
        guard let body = try? JSONDecoder().decode(Payload.self, from: payload), body.schema == 1 else {
            throw .malformed("not a pointer payload")
        }
        let pointer = body.pointer
        guard pointer.channel == channel else { throw .wrongChannel(pointer.channel) }
        try pointer.validate()
        return pointer
    }

    /// The archive's URL under `base` (`https://files.cmux.com/cmux-next-web/`).
    public func archiveURL(base: URL) -> URL {
        base.appending(path: key, directoryHint: .isDirectory).appending(path: archive, directoryHint: .notDirectory)
    }

    func validate() throws(WebUpdateRefusal) {
        guard Self.isHex(key, 64), Self.isHex(sha256, 64), Self.isHex(outputs, 64) else { throw .malformed("bad digest") }
        guard archive == "web-bundles-\(sha256).tar.gz" else { throw .malformed("archive name") }
        guard (1...Self.maximumSize).contains(size) else { throw .malformed("size \(size)") }
        guard Self.isHex(commit, 40), abi > 0, committedAt > 0 else { throw .malformed("commit or abi") }
    }

    static func isHex(_ text: String, _ count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    nonisolated struct Envelope: Decodable {
        nonisolated struct Signature: Decodable {
            var keyID: String
            var sig: String
            nonisolated enum CodingKeys: String, CodingKey { case keyID = "key_id", sig }
        }
        var schema: Int
        var payload: String
        var signatures: [Signature]
    }

    nonisolated struct Payload: Decodable {
        var schema: Int
        var pointer: WebUpdatePointer
        init(from decoder: any Decoder) throws {
            schema = try decoder.container(keyedBy: SchemaKey.self).decode(Int.self, forKey: .schema)
            pointer = try WebUpdatePointer(from: decoder)
        }
        nonisolated enum SchemaKey: String, CodingKey { case schema }
    }
}

/// The ed25519 keys a pointer may be signed with: `Resources/web-update-keys.json` of this module,
/// the same file CI's verify step reads.
nonisolated public struct WebUpdateKeys: Sendable {
    var keys: [String: Curve25519.Signing.PublicKey]

    /// The keys in `data`; an entry whose id is not the first 16 hex digits of its key's SHA-256
    /// is dropped.
    public init(json data: Data) {
        nonisolated struct File: Decodable {
            nonisolated struct Key: Decodable { var id: String; var ed25519: String }
            var keys: [Key]
        }
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for entry in (try? JSONDecoder().decode(File.self, from: data))?.keys ?? [] {
            guard let raw = Data(base64Encoded: entry.ed25519), raw.count == 32,
                  Self.id(of: raw) == entry.id,
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
            else { continue }
            keys[entry.id] = key
        }
        self.keys = keys
    }

    static func id(of raw: Data) -> String {
        SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// The keys this build trusts.
    public static let bundled: WebUpdateKeys = {
        let url = Bundle.module.url(forResource: "web-update-keys", withExtension: "json")
        return WebUpdateKeys(json: url.flatMap { try? Data(contentsOf: $0) } ?? Data())
    }()
}

/// Why a web update was not taken.
nonisolated public enum WebUpdateRefusal: Error, Equatable, Sendable {
    case malformed(String)
    /// No signature by a trusted key.
    case unsigned
    case wrongChannel(String)
    /// The bundles need another native interface than this app's.
    case abiMismatch(update: Int, app: Int)
    /// Older than the web this app shipped with or than the last update it took.
    case notNewer
    /// The download or the unpacked tree does not match the pointer.
    case integrity(String)
    case transfer(String)
}
