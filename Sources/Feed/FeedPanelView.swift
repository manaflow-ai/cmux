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
/// compact rows with SF Symbol + 13pt title + secondary metadata,
/// full-width hover backgrounds, and control-bar pill buttons styled
/// like `GroupingButton` in `SessionIndexView`.
///
/// Pending items float above resolved; telemetry is hidden unless the
/// user flips the Actionable / All filter. Rows receive immutable
/// snapshots + closure action bundles only (snapshot-boundary rule).
struct FeedPanelView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case actionable
        case activity
        var id: String { rawValue }
        var label: String {
            switch self {
            case .actionable:
                return String(localized: "feed.filter.actionable", defaultValue: "Actionable")
            case .activity:
                return String(localized: "feed.filter.activity", defaultValue: "All Activity")
            }
        }
        var symbolName: String {
            switch self {
            case .actionable: return "exclamationmark.circle"
            case .activity: return "checklist"
            }
        }
    }

    let placement: FeedPlacement
    let onFocusHostChange: (FeedKeyboardFocusView?) -> Void

    @State private var filter: Filter = .actionable
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
        VStack(spacing: 0) {
            controlBar
            FeedListView(
                filter: filter,
                presentation: viewModel.presentation,
                placement: placement,
                focusScopeID: focusScopeID,
                onFocusHostChange: onFocusHostChange,
                hasMorePersistedItems: viewModel.hasMorePersistedItems,
                isLoadingOlderItems: viewModel.isLoadingOlderItems,
                onLoadOlderItems: viewModel.loadOlderItems
            )
        }
    }

    private var controlBar: some View {
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 6) {
                    controlBarContent
                }
            } else {
                controlBarContent
            }
            #else
            controlBarContent
            #endif
        }
        .rightSidebarChromeBar(
            leadingPadding: placement == .pane
                ? HeaderChromeControlMetrics.titlebarControlsLeadingPadding
                : RightSidebarChromeMetrics.barHorizontalPadding
        )
        .rightSidebarChromeBottomBorder()
        .reportRightSidebarChromeGeometryForBonsplitUITest(role: .secondaryBar, isVisible: true, titlebarHeight: RightSidebarChromeMetrics.secondaryBarHeight)
    }

    private var controlBarContent: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { f in
                FeedSecondaryFilterButton(
                    filter: f,
                    isSelected: filter == f
                ) {
                    filter = f
                }
            }
            Spacer(minLength: 4)
        }
    }
}

private struct FeedSecondaryFilterButton: View {
    let filter: FeedPanelView.Filter
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: filter.symbolName)
                    .symbolRenderingMode(.monochrome)
                    .cmuxFont(
                        size: RightSidebarChromeControlStyle.secondaryIconSize,
                        weight: RightSidebarChromeControlStyle.iconWeight
                    )
                Text(filter.label)
                    .cmuxFont(
                        size: RightSidebarChromeControlStyle.labelSize,
                        weight: RightSidebarChromeControlStyle.labelWeight
                    )
            }
            .rightSidebarChromePill(
                isSelected: isSelected,
                isHovered: isHovered,
                geometryKeyPrefix: "rightSidebarSecondaryControl_feed_\(filter.rawValue)"
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(filter.label)
    }
}

/// Feed content surface. Isolated so the outer panel's `@State`
/// changes don't invalidate rows unnecessarily. Receives items as a
/// plain value so its body never touches the live store, the parent
/// owns the observation.
