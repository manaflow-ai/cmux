import CryptoKit
public import Foundation

/// The app's install key (P8 slice 3b-2, plans/cmux-next/identity.md):
/// 32 random bytes and an install id, kept by `FrontendInstallKeyStore`.
/// The app hands it to a daemon it starts (`server ensure
/// --install-key-stdin`, never argv or env) and proves itself on each new
/// connection with `client-hello`. The key never appears in a description.
public struct FrontendInstallKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let keyLength = 32
    /// Domain separation; the daemon checks the same bytes
    /// (`cmux_local_auth::frontend_proof::CONTEXT`).
    static let context = Data("cmux-frontend-hello-v1".utf8)

    public let installID: String
    let key: Data

    public init?(installID: String, key: Data) {
        guard Self.isValidInstallID(installID), key.count == Self.keyLength,
              key.contains(where: { $0 != 0 }) else { return nil }
        self.installID = installID
        self.key = key
    }

    /// A fresh key and install id (`inst_` + 20 random hex digits).
    public static func generate() -> FrontendInstallKey {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let suffix = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.hex.prefix(20)
        // Both values meet the checks above by construction (a random
        // 32-byte key is all zero with probability 2^-256).
        return FrontendInstallKey(checkedInstallID: "inst_\(suffix)", key: key)
    }

    private init(checkedInstallID: String, key: Data) {
        installID = checkedInstallID
        self.key = key
    }

    /// 1-128 ASCII letters, digits, `-` or `_` (the daemon's rule).
    public static func isValidInstallID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && id.utf8.allSatisfy { $0.isASCIIAlphanumeric || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
    }

    /// `cmuxik1 <install_id> <hex key>\n`: the launcher pipe payload, also
    /// the stored form.
    public var payload: Data { Data("cmuxik1 \(installID) \(key.hex)\n".utf8) }

    /// Parses `payload`.
    public init?(payload: Data) {
        guard let text = String(data: payload, encoding: .utf8) else { return nil }
        let words = text.trimmingCharacters(in: .newlines).split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[0] == "cmuxik1", let key = Data(hex: String(words[2])) else { return nil }
        self.init(installID: String(words[1]), key: key)
    }

    /// The `client-hello` step 2 proof over the daemon's nonce (hex):
    /// HMAC-SHA256(key, context || 0 || install_id || 0 || nonce).
    public func proof(nonce: Data) -> String {
        var message = Self.context
        message.append(0)
        message.append(Data(installID.utf8))
        message.append(0)
        message.append(nonce)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac).hex
    }

    /// `proof(nonce:)` for the nonce as the daemon sends it (64 hex
    /// digits); nil for anything else.
    public func proof(nonceHex: String) -> String? {
        guard nonceHex.utf8.count == 64, let nonce = Data(hex: nonceHex) else { return nil }
        return proof(nonce: nonce)
    }

    public var description: String { "FrontendInstallKey(\(installID))" }
    public var debugDescription: String { description }
}

fileprivate extension UInt8 {
    var isASCIIAlphanumeric: Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(self)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(self)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(self)
    }
}

fileprivate extension Data {
    /// Lowercase hex.
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// Exactly an even number of hex digits, else nil.
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = Self.nibble(digits[index]), let low = Self.nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
