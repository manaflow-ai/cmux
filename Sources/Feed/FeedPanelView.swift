import CmuxFoundation
import AppKit
import Bonsplit
import CMUXAgentLaunch
import SwiftUI
#if DEBUG
func feedDebugResponderSummary(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

extension WorkstreamPermissionMode {
    var displayLabel: String {
        switch self {
        case .once:
            return String(localized: "feed.permission.mode.once", defaultValue: "once")
        case .always:
            return String(localized: "feed.permission.mode.always", defaultValue: "always")
        case .all:
            return String(localized: "feed.permission.mode.all", defaultValue: "all tools")
        case .bypass:
            return String(localized: "feed.permission.mode.bypass", defaultValue: "bypass")
        case .deny:
            return String(localized: "feed.permission.mode.deny", defaultValue: "denied")
        }
    }
}

extension WorkstreamExitPlanMode {
    var displayLabel: String {
        switch self {
        case .ultraplan:
            return String(localized: "feed.exitplan.mode.ultraplan", defaultValue: "ultraplan")
        case .bypassPermissions:
            return String(localized: "feed.exitplan.mode.bypass", defaultValue: "bypass")
        case .autoAccept:
            return String(localized: "feed.exitplan.mode.autoAccept", defaultValue: "auto")
        case .manual:
            return String(localized: "feed.exitplan.mode.manual", defaultValue: "manual")
        case .deny:
            return String(localized: "feed.exitplan.mode.deny", defaultValue: "denied")
        }
    }
}
/// Right-sidebar Feed view. Matches the Sessions page visual language:
/// compact rows with SF Symbol + 13pt title + secondary metadata and
/// full-width hover backgrounds. Only actionable cards are retained.
struct FeedPanelView: View {
    let placement: FeedPlacement
    let onFocusHostChange: (FeedKeyboardFocusView?) -> Void

    @State private var viewModel = FeedPanelViewModel()
    @State private var focusScopeID = UUID()

    init(
        placement: FeedPlacement = .rightSidebar,
        onFocusHostChange: @escaping (FeedKeyboardFocusView?) -> Void = { _ in }
    ) {
        self.placement = placement
        self.onFocusHostChange = onFocusHostChange
    }

    var body: some View {
        FeedListView(
            presentation: viewModel.presentation,
            placement: placement,
            focusScopeID: focusScopeID,
            onFocusHostChange: onFocusHostChange
        )
    }
}

/// Feed content surface. Isolated so the outer panel's `@State`
/// changes don't invalidate rows unnecessarily. Receives items as a
/// plain value so its body never touches the live store, the parent
/// owns the observation.
