internal import CMUXMobileCore
import Foundation

/// Route authority expected from the authenticated Mac status handshake.
enum MobileMacInstanceTagExpectation: Equatable, Sendable {
    /// A fresh QR or legacy nil-tag row may adopt any authenticated tag.
    case adopt
    /// A stored connection keeps this tag when an older host omits it, but
    /// rejects a different nonnil tag.
    case preserve(String)
    /// An explicit registry-instance selection must prove this exact tag.
    case require(String)
}

enum MobileMacInstanceTagResolution: Equatable, Sendable {
    case accept(String?)
    case reject
}

struct MobileMacInstanceTagAuthority {
    private init() {}

    static func expectation(
        storedInstanceTag: String?
    ) -> MobileMacInstanceTagExpectation {
        guard let tag = normalized(storedInstanceTag) else { return .adopt }
        return .preserve(tag)
    }

    static func resolve(
        expectation: MobileMacInstanceTagExpectation,
        reportedInstanceTag: String?
    ) -> MobileMacInstanceTagResolution {
        let reported = normalized(reportedInstanceTag)
        switch expectation {
        case .adopt:
            return .accept(reported)
        case .preserve(let expected):
            let expected = normalized(expected)
            guard reported == nil || reported == expected else { return .reject }
            return .accept(expected)
        case .require(let expected):
            guard let expected = normalized(expected), reported == expected else { return .reject }
            return .accept(expected)
        }
    }

    static func authenticatedDeviceMatches(
        reportedDeviceID: String?,
        expectedDeviceID: String
    ) -> Bool {
        guard let reported = normalized(reportedDeviceID) else { return false }
        return cmxCanonicalDeviceID(reported) == cmxCanonicalDeviceID(expectedDeviceID)
    }

    static func sameStoredAuthority(_ lhs: String?, _ rhs: String?) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    /// Secondary aggregation is stricter than a foreground compatibility
    /// reconnect: it must authenticate the physical Mac, and an already-tagged
    /// record must prove that exact tag before any workspace is attributed to it.
    static func secondaryStatusMatches(
        expectedDeviceID: String,
        storedInstanceTag: String?,
        reportedDeviceID: String?,
        reportedInstanceTag: String?
    ) -> Bool {
        guard authenticatedDeviceMatches(
            reportedDeviceID: reportedDeviceID,
            expectedDeviceID: expectedDeviceID
        ) else { return false }
        guard let stored = normalized(storedInstanceTag) else { return true }
        return normalized(reportedInstanceTag) == stored
    }

    static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
