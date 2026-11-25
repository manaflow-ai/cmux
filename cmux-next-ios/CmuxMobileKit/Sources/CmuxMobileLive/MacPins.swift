import CryptoKit
import Foundation

/// The identity key of each Mac this phone paired with, pinned on first use
/// (PROTOCOL.md "Mac identity", #13742 draft gap 2). A Mac's cmux-mobile-host proves
/// its long-lived key in every `auth` (it signs this phone's nonce and the
/// challenge); after the first pairing, a Mac that proves another key, or none,
/// is refused, so a host registered with a stolen token cannot pass as it.
/// Removing the Mac in Settings forgets its pin; re-adding it pins again.
public final class MacPins: @unchecked Sendable {
    /// The app's pins (Application Support, one small JSON file; public keys only).
    public static let standard = MacPins(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("mac-pins.json"))

    /// One account's pins (Application Support `mac-pins-<user>.json`). The
    /// first call adopts the shared `mac-pins.json` of builds before per-account
    /// pins (it belonged to the account signed in then).
    public static func forAccount(_ userID: String) -> MacPins {
        let legacy = standardURL
        let safe = userID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        let url = legacy.deletingLastPathComponent().appendingPathComponent("mac-pins-\(safe).json")
        let files = FileManager.default
        if !files.fileExists(atPath: url.path), files.fileExists(atPath: legacy.path) {
            try? files.moveItem(at: legacy, to: url)
        }
        return MacPins(file: url)
    }

    static var standardURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("mac-pins.json")
    }

    /// Account deletion: this account's pins go.
    public func removeAll() {
        lock.withLock {
            pins = [:]
            if let file { try? FileManager.default.removeItem(at: file) }
        }
    }

    private let file: URL?
    private let lock = NSLock()
    private var pins: [String: String]

    /// `file` nil keeps the pins in memory (tests).
    public init(file: URL?) {
        self.file = file
        pins = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The pinned key of `mac` (X9.63, lowercase hex), if any.
    public func key(for mac: String) -> String? {
        lock.withLock { pins[mac.lowercased()] }
    }

    /// Pins `key` for `mac` (first pairing).
    public func pin(_ key: String, for mac: String) {
        lock.withLock {
            pins[mac.lowercased()] = key
            save()
        }
    }

    /// The person removed `mac`: its next pairing pins again.
    public func forget(_ mac: String) {
        lock.withLock {
            pins[mac.lowercased()] = nil
            save()
        }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(pins) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    /// The bytes a Mac's identity key signs (cmux-mobile-host `mac_proof_message`).
    public static func proofMessage(mac: String, phone: String, phoneNonce: String, challenge: String) -> Data {
        ApprovalPayload.joined("cmux-mobile-mac-identity-v1", [mac, phone, phoneNonce, challenge])
    }

    /// Whether `signature` (raw `r || s`, hex) by `key` (X9.63 hex) is valid over `message`.
    public static func verify(key: String, signature: String, message: Data) -> Bool {
        guard let keyBytes = Data(hex: key), let signatureBytes = Data(hex: signature),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: keyBytes),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes) else { return false }
        return publicKey.isValidSignature(ecdsa, for: message)
    }
}

extension Data {
    /// Lowercase or uppercase hex; nil for anything else.
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var high: UInt8?
        for unit in hex.utf8 {
            let nibble: UInt8
            switch unit {
            case 48...57: nibble = unit - 48
            case 97...102: nibble = unit - 87
            case 65...70: nibble = unit - 55
            default: return nil
            }
            if let h = high {
                bytes.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        self.init(bytes)
    }
}
