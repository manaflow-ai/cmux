public import Foundation

/// Native-side state machine guarding React Grab terminal paste-back.
///
/// A round trip is armed only by the user's explicit React Grab invocation
/// (shortcut, palette, or CLI action) with a terminal return target. Each arm
/// mints a fresh token that is handed exclusively to the cmux relay in the
/// React Grab isolated content world, never to page scripts. A delivery is
/// accepted at most once per arm (one-shot), only from the main frame, only
/// with the exact armed token (constant-time comparison), and only within the
/// content size bound.
public struct ReactGrabPastebackGate: Equatable, Sendable {
    /// Maximum accepted paste-back content size in UTF-8 bytes.
    ///
    /// The relay in the isolated world bounds content at
    /// ``ReactGrabBridgeScripts/maxContentLength`` UTF-16 units before
    /// forwarding; a UTF-16 unit expands to at most 3 UTF-8 bytes, so this
    /// native backstop is that bound times three.
    public static let maxContentUTF8Bytes = 393_216

    public enum DeliveryVerdict: Equatable, Sendable {
        case accepted(returnPanelId: UUID)
        case rejectedSubframe
        case rejectedUnarmed
        case rejectedTokenMismatch
        case rejectedOversizeContent
    }

    public private(set) var armedReturnPanelId: UUID?
    private var armedToken: String?

    public init() {}

    public var isArmed: Bool {
        armedReturnPanelId != nil && armedToken != nil
    }

    /// The token the isolated-world relay must present, for native-initiated
    /// sync into that world only. Never embed this in page-world scripts.
    public var tokenForRelaySync: String? {
        armedToken
    }

    /// Arms a round trip toward `returnPanelId` and mints a fresh token.
    /// Re-arming replaces any previous arm and invalidates its token.
    @discardableResult
    public mutating func arm(
        returnPanelId: UUID,
        token: String = ReactGrabPastebackGate.mintToken()
    ) -> String {
        armedReturnPanelId = returnPanelId
        armedToken = token
        return token
    }

    public mutating func disarm() {
        armedReturnPanelId = nil
        armedToken = nil
    }

    public static func mintToken() -> String {
        UUID().uuidString
    }

    /// Judges one delivery attempt. Any armed outcome other than a subframe
    /// rejection consumes the arm, so a token can never be replayed; a
    /// subframe attempt cannot burn the user's arm because the main-frame
    /// relay is the only holder of the token.
    public mutating func acceptDelivery(
        token: String?,
        contentUTF8Count: Int,
        isMainFrame: Bool
    ) -> DeliveryVerdict {
        guard isMainFrame else { return .rejectedSubframe }
        guard let returnPanelId = armedReturnPanelId, let expectedToken = armedToken else {
            return .rejectedUnarmed
        }
        guard let token, Self.constantTimeEquals(token, expectedToken) else {
            disarm()
            return .rejectedTokenMismatch
        }
        disarm()
        guard contentUTF8Count <= Self.maxContentUTF8Bytes else {
            return .rejectedOversizeContent
        }
        return .accepted(returnPanelId: returnPanelId)
    }

    /// Compares two strings in time independent of where they first differ.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = lhsBytes.count ^ rhsBytes.count
        var index = 0
        let count = max(lhsBytes.count, rhsBytes.count)
        while index < count {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
            index += 1
        }
        return difference == 0
    }
}
