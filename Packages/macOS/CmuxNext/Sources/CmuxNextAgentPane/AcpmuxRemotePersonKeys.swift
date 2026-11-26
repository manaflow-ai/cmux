public import Foundation
import CommonCrypto
import Security
import CmuxNextCompat

/// A person key this app made for an acpmux daemon on another machine (cx-0q7o slice 2c, acpmux
/// `hub/person.rs`). The 32 bytes live in one buffer this object allocates, never in an array,
/// `Data` or `String` (each is copy-on-write and keeps copies nobody zeroes). The buffer is zeroed
/// with `memset_s` when the object is released: the store releases it when the key is replaced or
/// dropped. HMACs run with CommonCrypto's `CCHmac` straight on this buffer: no other copy of the
/// key is made.
public nonisolated final class AcpmuxSecretKey: @unchecked Sendable { // crash-allow: the buffer is written once in init, then only read; zeroed in deinit
    static let length = 32
    private let bytes: UnsafeMutableRawBufferPointer

    /// A new random key; nil when the system has no randomness.
    public init?() {
        bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.length, alignment: 1)
        guard let base = bytes.baseAddress, SecRandomCopyBytes(kSecRandomDefault, Self.length, base) == errSecSuccess else {
            Self.zero(bytes)
            bytes.deallocate()
            return nil
        }
    }

    /// The key of 64 lowercase hex digits (tests: a key acpmux's own tests use too).
    init?(hex: String) {
        // Parsed before the buffer exists, so a bad digit fails with nothing to free.
        let hexDigits = Set("0123456789abcdef".utf8)
        let digits = Array(hex.utf8)
        guard digits.count == Self.length * 2, digits.allSatisfy(hexDigits.contains) else { return nil }
        let parsed = (0..<Self.length).compactMap {
            UInt8(String(decoding: digits[($0 * 2)...($0 * 2 + 1)], as: UTF8.self), radix: 16)
        }
        guard parsed.count == Self.length else { return nil }
        bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.length, alignment: 1)
        bytes.copyBytes(from: parsed)
    }

    deinit {
        Self.zero(bytes)
        bytes.deallocate()
    }

    private static func zero(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress else { return }
        _ = memset_s(base, buffer.count, 0, buffer.count)
    }

    /// Lowercase hex HMAC-SHA256(key, domain 0 part 0 part ...), as acpmux builds its messages.
    func mac(domain: String, parts: [String]) -> String {
        var message = Array(domain.utf8)
        for part in parts {
            message.append(0)
            message.append(contentsOf: part.utf8)
        }
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        message.withUnsafeBytes { text in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), bytes.baseAddress, bytes.count, text.baseAddress, text.count, &out)
        }
        return out.map { String(format: "%02x", $0) }.joined()
    }

    /// `personDecision` of a relayed allow (acpmux `decision_proof`).
    public func decisionProof(instance: String, session: String, permission: String, option: String, nonce: String) -> String {
        mac(domain: "acpmux-person-decision-v1", parts: [instance, session, permission, option, nonce])
    }

    /// What a daemon run that holds this key answers to `_acpmux/person_holds` (acpmux `holds`).
    public func holdsProof(instance: String, nonce: String) -> String {
        mac(domain: "acpmux-person-holds-v1", parts: [instance, nonce])
    }

    /// Writes the key as one line of lowercase hex to `descriptor` (the stdin of the app's own ssh
    /// exec), from a buffer that is zeroed right after. False when the line did not go out whole.
    @discardableResult
    public func writeLine(to descriptor: Int32) -> Bool {
        withLine { base, count in
            var offset = 0
            while offset < count {
                let written = Darwin.write(descriptor, base + offset, count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Writes the key line to `stream` (the body of the app's own keyed-start request to the
    /// Cloud service, cx-psxg), from a buffer that is zeroed right after. False when the line
    /// did not go out whole.
    @discardableResult
    public func writeLine(to stream: OutputStream) -> Bool {
        withLine { base, count in
            var offset = 0
            while offset < count {
                let written = stream.write(base.assumingMemoryBound(to: UInt8.self) + offset, maxLength: count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// The length of the key line: 64 hex characters and a newline.
    public static var lineLength: Int { length * 2 + 1 }

    /// The key line in one buffer of its own, zeroed after `body`.
    private func withLine(_ body: (UnsafeMutableRawPointer, Int) -> Bool) -> Bool {
        let line = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.lineLength, alignment: 1)
        defer {
            Self.zero(line)
            line.deallocate()
        }
        let digits: StaticString = "0123456789abcdef"
        digits.withUTF8Buffer { hex in
            for index in 0..<Self.length {
                let byte = bytes[index]
                line[2 * index] = hex[Int(byte >> 4)]
                line[2 * index + 1] = hex[Int(byte & 0x0F)]
            }
        }
        line[Self.length * 2] = 0x0A
        guard let base = line.baseAddress else { return false }
        return body(base, line.count)
    }

    /// Whether `proof` is what a daemon run `instance` that holds this key answers to
    /// `_acpmux/person_holds {nonce}` (constant-time compare).
    public func holds(proof: String, instance: String, nonce: String) -> Bool {
        Self.proofsMatch(proof, holdsProof(instance: instance, nonce: nonce))
    }

    /// A fresh 32-byte nonce as lowercase hex, for `_acpmux/person_holds`.
    public static func newNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether two lowercase hex proofs are equal, in time that does not depend on where they differ.
    public static func proofsMatch(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }
}

/// The person keys this app gave acpmux daemons on other machines, by machine, each bound to the
/// daemon run (`personInstance`) that proved it holds the key (`_acpmux/person_holds`). Memory
/// only: after a relaunch every remote daemon is unkeyed until a keyed restart from the pane.
public nonisolated final class AcpmuxRemotePersonKeys: Sendable {
    public static let shared = AcpmuxRemotePersonKeys()

    private struct Entry {
        let instance: String
        let key: AcpmuxSecretKey
    }

    private let entries = Mutex<[String: Entry]>([:])

    public init() {}

    /// `machine`'s daemon run `instance` holds `key`. A key the machine had before is released
    /// (and so zeroed).
    public func bind(machine: String, instance: String, key: AcpmuxSecretKey) {
        let old = entries.withLock { $0.updateValue(Entry(instance: instance, key: key), forKey: machine) }
        _ = old
    }

    /// Forgets `machine`'s key (its daemon is no longer the one the app started).
    public func drop(machine: String) {
        let old = entries.withLock { $0.removeValue(forKey: machine) }
        _ = old
    }

    /// The key bound to `machine`, when its bound daemon run is `instance` (the run that asks).
    /// Never a key of another machine.
    public func key(machine: String, instance: String) -> AcpmuxSecretKey? {
        entries.withLock { entries in entries[machine].flatMap { $0.instance == instance ? $0.key : nil } }
    }

    /// The daemon run of `machine` that holds this app's key.
    public func instance(machine: String) -> String? {
        entries.withLock { $0[machine]?.instance }
    }
}
