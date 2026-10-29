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
///
/// Memory safety: `bytes` is the one allocation of `length` bytes that `init` made and filled; it is
/// freed once, in deinit (a failed fill frees its buffer before `bytes` is set, so deinit never sees
/// it). Every index below is under `length`, and a key line's buffer lives only for ``withLine(_:)``.
@safe
public nonisolated final class AcpmuxSecretKey: @unchecked Sendable { // crash-allow: the buffer is written once in init, then only read; zeroed in deinit
    static let length = 32
    private let bytes: UnsafeMutableRawBufferPointer

    /// A new random key; nil when the system has no randomness.
    public init?() {
        // SAFETY: a new allocation of `length` bytes, owned here: freed below when the fill fails, else in deinit.
        let buffer = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: Self.length, alignment: 1)
        // SAFETY: SecRandomCopyBytes writes exactly `length` bytes, the allocation's size, from its base.
        guard let base = unsafe buffer.baseAddress, unsafe SecRandomCopyBytes(kSecRandomDefault, Self.length, base) == errSecSuccess else {
            // SAFETY: the allocation above, zeroed and freed once; `bytes` was never set, so deinit does not run.
            unsafe Self.zero(buffer)
            unsafe buffer.deallocate()
            return nil
        }
        unsafe bytes = buffer
    }

    deinit {
        // SAFETY: the allocation of init, zeroed and freed once; nothing else holds `self` any more.
        unsafe Self.zero(bytes)
        unsafe bytes.deallocate()
    }

    private static func zero(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = unsafe buffer.baseAddress else { return }
        // SAFETY: memset_s writes buffer.count zeros from the buffer's base: exactly its own bytes.
        _ = unsafe memset_s(base, buffer.count, 0, buffer.count)
    }

    /// Lowercase hex HMAC-SHA256(key, domain 0 part 0 part ...), as acpmux builds its messages.
    func mac(domain: String, parts: [String]) -> String {
        var message = Array(domain.utf8)
        for part in parts {
            message.append(0)
            message.append(contentsOf: part.utf8)
        }
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        // SAFETY: CCHmac reads bytes.count key bytes from the key buffer (allocated, see the type), message.count
        // bytes from the message array and writes one SHA-256 digest (out.count bytes) into `out`; the arrays are
        // lent for the call.
        unsafe CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), bytes.baseAddress, bytes.count, message, message.count, &out)
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
        unsafe withLine { base, count in
            var offset = 0
            while offset < count {
                // SAFETY: base is the line's buffer of `count` bytes (withLine), live for this closure; 0 <= offset
                // < count (the loop's condition), so the write covers the count - offset bytes left.
                let written = unsafe blockingWrite(descriptor, base + offset, count - offset)
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
        unsafe withLine { base, count in
            var offset = 0
            while offset < count {
                // SAFETY: base is the line's buffer of `count` bytes (withLine), live for this closure and written only
                // as bytes, so reading it as UInt8 is its own type; 0 <= offset < count (the loop's condition).
                let written = unsafe stream.write(base.assumingMemoryBound(to: UInt8.self) + offset, maxLength: count - offset)
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
        // SAFETY: a new allocation of lineLength bytes, owned by this call and zeroed and freed once by the defer;
        // `body` gets it only for its own call.
        let line = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: Self.lineLength, alignment: 1)
        defer {
            unsafe Self.zero(line)
            unsafe line.deallocate()
        }
        let hex = Array("0123456789abcdef".utf8)
        for index in 0..<Self.length {
            // SAFETY: index < length, the key buffer's size, and 2 * index + 1 < length * 2 < lineLength, the line's.
            let byte = unsafe bytes[index]
            unsafe line[2 * index] = hex[Int(byte >> 4)]
            unsafe line[2 * index + 1] = hex[Int(byte & 0x0F)]
        }
        // SAFETY: length * 2 == lineLength - 1, the line's last byte.
        unsafe line[Self.length * 2] = 0x0A
        guard let base = unsafe line.baseAddress else { return false }
        return unsafe body(base, line.count)
    }

    /// Whether `proof` is what a daemon run `instance` that holds this key answers to
    /// `_acpmux/person_holds {nonce}` (constant-time compare).
    public func holds(proof: String, instance: String, nonce: String) -> Bool {
        Self.proofsMatch(proof, holdsProof(instance: instance, nonce: nonce))
    }

    /// A fresh 32-byte nonce as lowercase hex, for `_acpmux/person_holds`.
    public static func newNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        // SAFETY: SecRandomCopyBytes writes bytes.count bytes into the array's own storage, lent for the call.
        guard unsafe SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
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
