internal import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// A fresh/manual attach may adopt a reported tag, including switching an
    /// existing row to a different authenticated instance. When status reports
    /// no tag, however, it cannot mutate routes already owned by a tagged row.
    func adoptWouldConflictWithStoredInstanceAuthority(
        expectation: MobileMacInstanceTagExpectation,
        reportedInstanceTag: String?,
        macDeviceID: String?
    ) async -> Bool {
        guard case .adopt = expectation,
              MobileMacInstanceTagAuthority.normalized(reportedInstanceTag) == nil,
              let macDeviceID = macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !macDeviceID.isEmpty,
              let pairedMacStore,
              let scope = await currentScopeSnapshot() else { return false }
        let canonicalDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let existing = try? await pairedMacStore.loadAll(
            stackUserID: scope.userID,
            teamID: scope.teamID
        ).first { cmxCanonicalDeviceID($0.macDeviceID) == canonicalDeviceID }
        guard await isScopeCurrent(scope) else { return true }
        return MobileMacInstanceTagAuthority.normalized(existing?.instanceTag) != nil
    }
}
