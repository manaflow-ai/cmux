internal import CMUXMobileCore
import Foundation

/// Owns the identity and instance-tag rules shared by foreground reconnects,
/// registry refreshes, and secondary control connections.
struct MobileMacInstanceTagAuthority: Sendable {
    private let canonicalizeDeviceID: @Sendable (String) -> String

    init(
        canonicalizeDeviceID: @escaping @Sendable (String) -> String = {
            cmxCanonicalDeviceID($0)
        }
    ) {
        self.canonicalizeDeviceID = canonicalizeDeviceID
    }

    func expectation(
        storedInstanceTag: String?
    ) -> MobileMacInstanceTagExpectation {
        guard let tag = normalize(storedInstanceTag) else {
            return .adopt
        }
        return .preserve(tag)
    }

    func resolve(
        expectation: MobileMacInstanceTagExpectation,
        reportedInstanceTag: String?
    ) -> MobileMacInstanceTagResolution {
        let reported = normalize(reportedInstanceTag)
        switch expectation {
        case .adopt:
            return .accept(reported)
        case .preserve(let expected):
            let expected = normalize(expected)
            guard reported == nil || reported == expected else {
                return .reject
            }
            return .accept(expected)
        case .require(let expected):
            guard let expected = normalize(expected),
                  reported == expected else {
                return .reject
            }
            return .accept(expected)
        }
    }

    func authenticatedDeviceMatches(
        reportedDeviceID: String?,
        expectedDeviceID: String
    ) -> Bool {
        guard let reported = normalize(reportedDeviceID) else {
            return false
        }
        return canonicalizeDeviceID(reported)
            == canonicalizeDeviceID(expectedDeviceID)
    }

    func sameStoredAuthority(_ lhs: String?, _ rhs: String?) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    /// Secondary aggregation requires a physical-Mac identity. An already
    /// tagged record must also prove that exact tag before publishing state.
    func secondaryStatusMatches(
        expectedDeviceID: String,
        storedInstanceTag: String?,
        reportedDeviceID: String?,
        reportedInstanceTag: String?
    ) -> Bool {
        secondaryStatusAuthority(
            expectedDeviceID: expectedDeviceID,
            storedInstanceTag: storedInstanceTag,
            reportedDeviceID: reportedDeviceID,
            reportedInstanceTag: reportedInstanceTag
        ) == .accepted
    }

    func secondaryStatusAuthority(
        expectedDeviceID: String,
        storedInstanceTag: String?,
        reportedDeviceID: String?,
        reportedInstanceTag: String?
    ) -> MobileSecondaryStatusAuthority {
        guard normalize(reportedDeviceID) != nil else {
            return .identityUnavailable
        }
        guard authenticatedDeviceMatches(
            reportedDeviceID: reportedDeviceID,
            expectedDeviceID: expectedDeviceID
        ) else {
            return .rejected
        }
        guard let stored = normalize(storedInstanceTag) else {
            return .accepted
        }
        return normalize(reportedInstanceTag) == stored
            ? .accepted
            : .rejected
    }

    func normalize(_ value: String?) -> String? {
        guard let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
