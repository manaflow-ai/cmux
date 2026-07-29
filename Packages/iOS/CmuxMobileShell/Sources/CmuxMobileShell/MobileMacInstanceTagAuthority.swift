internal import CMUXMobileCore
import Foundation

func mobileMacInstanceTagExpectation(
    storedInstanceTag: String?
) -> MobileMacInstanceTagExpectation {
    guard let tag = normalizedMobileMacIdentityValue(storedInstanceTag) else {
        return .adopt
    }
    return .preserve(tag)
}

func resolveMobileMacInstanceTag(
    expectation: MobileMacInstanceTagExpectation,
    reportedInstanceTag: String?
) -> MobileMacInstanceTagResolution {
    let reported = normalizedMobileMacIdentityValue(reportedInstanceTag)
    switch expectation {
    case .adopt:
        return .accept(reported)
    case .preserve(let expected):
        let expected = normalizedMobileMacIdentityValue(expected)
        guard reported == nil || reported == expected else { return .reject }
        return .accept(expected)
    case .require(let expected):
        guard let expected = normalizedMobileMacIdentityValue(expected),
              reported == expected else {
            return .reject
        }
        return .accept(expected)
    }
}

func mobileMacAuthenticatedDeviceMatches(
    reportedDeviceID: String?,
    expectedDeviceID: String
) -> Bool {
    guard let reported = normalizedMobileMacIdentityValue(reportedDeviceID) else {
        return false
    }
    return cmxCanonicalDeviceID(reported)
        == cmxCanonicalDeviceID(expectedDeviceID)
}

func mobileMacStoredAuthorityMatches(_ lhs: String?, _ rhs: String?) -> Bool {
    normalizedMobileMacIdentityValue(lhs)
        == normalizedMobileMacIdentityValue(rhs)
}

/// Secondary aggregation is stricter than a foreground compatibility
/// reconnect: it must authenticate the physical Mac, and an already-tagged
/// record must prove that exact tag before any workspace is attributed to it.
func mobileSecondaryStatusMatches(
    expectedDeviceID: String,
    storedInstanceTag: String?,
    reportedDeviceID: String?,
    reportedInstanceTag: String?
) -> Bool {
    mobileSecondaryStatusAuthority(
        expectedDeviceID: expectedDeviceID,
        storedInstanceTag: storedInstanceTag,
        reportedDeviceID: reportedDeviceID,
        reportedInstanceTag: reportedInstanceTag
    ) == .accepted
}

func normalizedMobileMacIdentityValue(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

func mobileSecondaryStatusAuthority(
    expectedDeviceID: String,
    storedInstanceTag: String?,
    reportedDeviceID: String?,
    reportedInstanceTag: String?
) -> MobileSecondaryStatusAuthority {
    guard normalizedMobileMacIdentityValue(reportedDeviceID) != nil else {
        return .identityUnavailable
    }
    guard mobileMacAuthenticatedDeviceMatches(
        reportedDeviceID: reportedDeviceID,
        expectedDeviceID: expectedDeviceID
    ) else {
        return .rejected
    }
    guard let stored = normalizedMobileMacIdentityValue(
        storedInstanceTag
    ) else {
        return .accepted
    }
    return normalizedMobileMacIdentityValue(reportedInstanceTag)
        == stored
        ? .accepted
        : .rejected
}
