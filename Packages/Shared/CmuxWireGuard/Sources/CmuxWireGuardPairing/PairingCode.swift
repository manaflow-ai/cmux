public import Foundation
import CryptoKit

/// The typed form of a pairing invitation: eight Crockford base32 symbols
/// shown as XXXX-XXXX (40 bits).
///
/// The code is the invitation's secret. With the Mac's public key as salt,
/// HKDF derives the one-time bootstrap key, the preshared key and the
/// bootstrap address, so the QR code and the typed code name the same
/// single-use invitation. A phone that knows the code and finds the Mac on
/// the local network can rebuild the invitation without the QR code.
public struct PairingCode: Hashable, Sendable, CustomStringConvertible {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Eight symbols, uppercase, no dash.
    public let symbols: String

    /// A fresh random code.
    public init() {
        var generator = SystemRandomNumberGenerator()
        symbols = String((0..<8).map { _ in Self.alphabet[Int(generator.next() % 32)] })
    }

    /// Parses user input: case, dashes and spaces are ignored; O reads as 0,
    /// I and L as 1 (Crockford).
    public init?(_ text: String) {
        var cleaned = ""
        for character in text.uppercased() where character != "-" && !character.isWhitespace {
            switch character {
            case "O": cleaned.append("0")
            case "I", "L": cleaned.append("1")
            default:
                guard Self.alphabet.contains(character) else { return nil }
                cleaned.append(character)
            }
        }
        guard cleaned.count == 8 else { return nil }
        symbols = cleaned
    }

    /// "ABCD-EFGH".
    public var description: String { "\(symbols.prefix(4))-\(symbols.suffix(4))" }

    /// The invitation secrets this code derives for the Mac with `hostKey`.
    public func derive(hostKey: WireGuardKey) -> (bootstrapKey: WireGuardKey, presharedKey: WireGuardKey, addressIndex: Int) {
        let material = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(symbols.utf8)),
                                             salt: hostKey.rawValue, info: Data("cmux-wg pairing v1".utf8),
                                             outputByteCount: 65)
        let bytes = material.withUnsafeBytes { Data($0) }
        let bootstrap = WireGuardKey(rawValue: bytes.prefix(32)) ?? WireGuardKey()
        let psk = WireGuardKey(rawValue: bytes.dropFirst(32).prefix(32)) ?? WireGuardKey(randomPresharedKey: ())
        let index = Int(bytes.last ?? 0) % 254 + 1
        return (bootstrap, psk, index)
    }
}

extension PairingInvitation {
    /// The invitation a typed code stands for, for a Mac found on the local
    /// network (its name, id and key from its advertisement).
    public init(code: PairingCode, hostName: String, hostID: String, hostKey: WireGuardKey, endpoints: [String],
                plan: OverlayPlan = OverlayPlan(), expiresAt: Date) {
        let derived = code.derive(hostKey: hostKey)
        self.init(hostName: hostName, hostID: hostID, hostKey: hostKey, endpoints: endpoints,
                  bootstrapKey: derived.bootstrapKey,
                  bootstrapAddress: plan.bootstrapAddress(derived.addressIndex) ?? "10.77.1.1",
                  presharedKey: derived.presharedKey, hostAddress: plan.hostAddress, expiresAt: expiresAt)
    }
}
