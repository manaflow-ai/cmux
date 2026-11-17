// SPDX-License-Identifier: GPL-3.0-or-later
import CmuxDeviceHub
import Foundation

/// The Screen Sharing worker's strings (Resources/Localizable.xcstrings; the
/// same keys and translations as the app's Mac Screen strings).
struct HelperText: Sendable {
    static func t(_ key: String, _ english: String) -> String {
        Bundle.module.localizedString(forKey: key, value: english, table: nil)
    }
}

/// The approval banner's four answers (the same as the app's Mac Screen prompt).
enum ApprovalChoice: String, CaseIterable, Sendable {
    case deny, once, alwaysView, alwaysFull

    /// The hub decision, the session scope (lowered, never raised) and a permission to store after.
    func answer(requested: SessionScope) -> (decision: SessionDecision, scope: SessionScope, thenPermission: DeviceScope?) {
        switch self {
        case .deny: (.deny, requested, nil)
        case .once: (.once, requested, nil)
        case .alwaysView: (.always, .view, nil)
        case .alwaysFull: requested == .full ? (.always, .full, nil) : (.always, .view, .full)
        }
    }

    var title: String {
        switch self {
        case .deny: HelperText.t("macScreen.approval.deny", "Deny")
        case .once: HelperText.t("macScreen.approval.once", "Allow Once")
        case .alwaysView: HelperText.t("macScreen.approval.alwaysView", "Always Allow View Only")
        case .alwaysFull: HelperText.t("macScreen.approval.alwaysFull", "Always Allow Full Control")
        }
    }
}

extension SessionScope {
    var remoteTitle: String {
        switch self {
        case .view: HelperText.t("macScreen.scope.view", "View Only")
        case .full: HelperText.t("macScreen.scope.full", "Full Control")
        }
    }
}
