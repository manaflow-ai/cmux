// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation
import CryptoKit

/// A phone's answer to an approval question, as cmux-mobile-host forwards it
/// (`cu_approval_answer`, docs/computer-use-approvals.md "Phone wire"). The app checks it
/// again itself: hostd's word alone never grants.
public nonisolated struct ComputerUseApprovalPhoneAnswer: Sendable, Equatable {
    public var phoneDeviceID: String
    public var digest: String
    public var decision: ComputerUseApprovalDecision
    /// Unix seconds.
    public var expiresAt: Int64
    /// Raw `r || s`, lowercase hex, by the phone's approval key (Face ID); nil for a deny.
    public var signature: String?

    public init(phoneDeviceID: String, digest: String, decision: ComputerUseApprovalDecision, expiresAt: Int64, signature: String?) {
        self.phoneDeviceID = phoneDeviceID
        self.digest = digest
        self.decision = decision
        self.expiresAt = expiresAt
        self.signature = signature
    }

    /// The longest an answer may stay valid ahead of this Mac's clock.
    public static let maximumLifetime: Int64 = 300

    /// `cmux-cu-phone-approval-v1 \0 phone \0 digest \0 decision \0 expiresAt`.
    public static func message(phone: String, digest: String, decision: ComputerUseApprovalDecision, expiresAt: Int64) -> Data {
        Data(["cmux-cu-phone-approval-v1", phone, digest, decision.rawValue, String(expiresAt)].joined(separator: "\u{0}").utf8)
    }

    public var message: Data { Self.message(phone: phoneDeviceID, digest: digest, decision: decision, expiresAt: expiresAt) }

    /// Whether this answer was made by the holder of `approvalKey` (X9.63 hex) within its window.
    /// A deny needs no signature; every allow does.
    public func isValid(approvalKey: String?, nowSeconds: Int64) -> Bool {
        guard nowSeconds <= expiresAt, expiresAt <= nowSeconds + Self.maximumLifetime else { return false }
        guard decision.allows else { return true }
        guard let approvalKey, let signature, let keyBytes = Self.bytes(hex: approvalKey), let signatureBytes = Self.bytes(hex: signature),
              let key = try? P256.Signing.PublicKey(x963Representation: keyBytes),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes) else { return false }
        return key.isValidSignature(ecdsa, for: message)
    }

    static func bytes(hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x61...0x66: byte - 0x61 + 10
        case 0x41...0x46: byte - 0x41 + 10
        default: nil
        }
    }
}

/// Where the app sends approval questions to the owner's phone (cmux-mobile-host's
/// `cu_approval` / `cu_approval_done`). The App wires it to the iPhone host.
@MainActor
public protocol ComputerUseApprovalPhoneRelay: AnyObject {
    /// Pushes `request`; `allowsAlways` offers Always Allow on the phone.
    func ask(_ request: ComputerUseApprovalRequest, allowsAlways: Bool)
    /// The question is settled or gone.
    func done(digest: String)
}
