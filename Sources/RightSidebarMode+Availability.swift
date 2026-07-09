import AppKit
import CmuxSidebar
import Foundation

// The pure CLI-argument decode and the gate-based availability/availableModes
// now live in CmuxSidebar (RightSidebarMode). These app-target overloads bind
// the `feedEnabled`/`dockEnabled` gates to the live `UserDefaults`-backed
// RightSidebarBetaFeatureSettings, which stays in the app target.
extension RightSidebarMode {
    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }
}

enum RightSidebarKeyboardNavigation {
    enum DisclosureAction {
        case collapse
        case expand
    }

    static func moveDelta(for event: NSEvent) -> Int? {
        event.rightSidebarMoveDelta
    }

    static func disclosureAction(for event: NSEvent) -> DisclosureAction? {
        switch event.rightSidebarDisclosureAction {
        case .collapse:
            return .collapse
        case .expand:
            return .expand
        case nil:
            return nil
        }
    }

    static func isPlainSlash(_ event: NSEvent) -> Bool {
        event.isPlainRightSidebarSlash
    }

    static func isPlainPrintableText(_ event: NSEvent) -> Bool {
        event.isPlainRightSidebarPrintableText
    }
}
