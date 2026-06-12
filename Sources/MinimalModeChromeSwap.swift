import AppKit
import SwiftUI

// Minimal-mode toggle hot path (https://github.com/manaflow-ai/cmux/issues/5732).
//
// `workspacePresentationMode` used to be observed via `@AppStorage` directly on
// three large view bodies: `ContentView` (window root), `VerticalTabsSidebar`,
// and every mounted `WorkspaceContentView`. Toggling minimal mode invalidated
// all of them in one synchronous AttributeGraph transaction, and because the
// re-evaluated parents rebuilt children whose stored closures defeat SwiftUI's
// implicit diffing, the whole Bonsplit subtree and sidebar re-rendered even
// though the mode only changes a top safe-area edge and a small titlebar
// controls strip. The pieces below keep the mode subscription on leaf views so
// a toggle re-evaluates only the chrome that actually changes; the heavy
// subtrees keep their stored view values and only re-layout.

/// Applies the minimal-mode top safe-area cancellation to a workspace's
/// Bonsplit subtree while owning the presentation-mode subscription. On a
/// toggle only this wrapper's body re-runs; `content` is the stored view value
/// from the workspace body, so SwiftUI skips its body and just re-layouts.
struct MinimalModeSafeAreaBridge<Content: View>: View {
    let isFullScreen: Bool
    let content: Content

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    init(isFullScreen: Bool, @ViewBuilder content: () -> Content) {
        self.isFullScreen = isFullScreen
        self.content = content()
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        content
            .ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])
    }
}

/// `ContentView.terminalContent` mounts each workspace with `.equatable()` so
/// the window-root body re-evaluation a minimal-mode toggle requires (titlebar
/// band mount/unmount) no longer re-evaluates every mounted workspace's
/// Bonsplit tree. Closures and observed stores are excluded: `workspace` and
/// `notificationStore` invalidate the view through their own subscriptions,
/// and `onThemeRefreshRequest` only routes to stable owner state.
extension WorkspaceContentView: Equatable {
    nonisolated static func == (lhs: WorkspaceContentView, rhs: WorkspaceContentView) -> Bool {
        // EquatableView diffing runs on the main thread; hop in explicitly to
        // read the MainActor-isolated @ObservedObject storage. If SwiftUI ever
        // compares off-main, fall back to "not equal" — an extra render is
        // always safe, a stale skip is not.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            lhs.workspace === rhs.workspace &&
            lhs.isWorkspaceVisible == rhs.isWorkspaceVisible &&
            lhs.isWorkspaceInputActive == rhs.isWorkspaceInputActive &&
            lhs.isFullScreen == rhs.isFullScreen &&
            lhs.workspacePortalPriority == rhs.workspacePortalPriority
        }
    }
}

/// Mounts the standard-mode workspace titlebar band. Owns the
/// presentation-mode subscription so the band mount/unmount on toggle does not
/// require re-evaluating the window-root `ContentView` body. The band content
/// is the stored view value from the last `ContentView` render (the band's own
/// inputs — appearance, titles, sidebar width — all re-render `ContentView`
/// when they change, so the stored value is always current).
struct MinimalModeTitlebarBandHost<Band: View>: View {
    let band: Band
    /// Runs the AppKit side effects of a mode flip (window decorations,
    /// chrome metrics, traffic-light inset, portal geometry). Replaces the
    /// `onChange(of: isMinimalMode)` that previously lived on `ContentView`.
    let onModeChange: () -> Void

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    init(onModeChange: @escaping () -> Void, @ViewBuilder band: () -> Band) {
        self.onModeChange = onModeChange
        self.band = band()
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        Group {
            if !isMinimalMode {
                band
            }
        }
        .onChange(of: isMinimalMode) { _, _ in
            onModeChange()
        }
    }
}

/// Applies the mode-dependent top padding to the window's terminal content.
/// Standard mode reserves the cmux titlebar band height; minimal mode cancels
/// any AppKit-reported safe area instead. Owning the mode subscription here
/// means a toggle re-layouts the stored content without re-evaluating
/// `ContentView` or the content subtree.
struct MinimalModeContentTopPaddingBridge<Content: View>: View {
    let isFullScreen: Bool
    let titlebarPadding: CGFloat
    let hostingSafeAreaTop: CGFloat
    let content: Content

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    init(
        isFullScreen: Bool,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.isFullScreen = isFullScreen
        self.titlebarPadding = titlebarPadding
        self.hostingSafeAreaTop = hostingSafeAreaTop
        self.content = content()
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        content
            .padding(.top, ContentView.effectiveTitlebarPadding(
                isMinimalMode: isMinimalMode,
                isFullScreen: isFullScreen,
                titlebarPadding: titlebarPadding,
                hostingSafeAreaTop: hostingSafeAreaTop
            ))
    }
}

/// Hosts the minimal-mode titlebar event surface (drag/double-click routing
/// behind the chrome) with its own mode subscription.
struct MinimalModeTitlebarEventSurfaceHost: View {
    let isFullScreen: Bool

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        MinimalModeTitlebarEventSurfaceView(isEnabled: isMinimalMode && !isFullScreen)
    }
}

/// Owns the titlebar debug-inset subscriptions on a leaf and reapplies window
/// decorations when they actually change. The keys contain dots
/// (`titlebarDebug.…`), which breaks `@AppStorage`'s per-key KVO — SwiftUI
/// falls back to invalidating the holder on every `UserDefaults` write — so
/// the window-root `ContentView` must not hold them itself (#5732).
struct TitlebarDebugChromeSentinel: View {
    let onDebugChromeChange: () -> Void

    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
    private var leftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
    private var leftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey)
    private var trafficLightTabBarInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey)
    private var trafficLightTitlebarLeadingInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset

    private var snapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                leftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.clamped(
                leftControlsTopInset,
                range: MinimalModeTitlebarDebugSettings.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                trafficLightTabBarInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                trafficLightTitlebarLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            )
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: snapshot) { _, _ in
                onDebugChromeChange()
            }
    }
}

/// Precise invalidation source for the extension-sidebar provider selection.
/// `@AppStorage` cannot observe `cmuxExtensionSidebar.providerId` per key (the
/// dot breaks KVO key registration and SwiftUI falls back to invalidating the
/// holder on every `UserDefaults` write), which re-ran the entire
/// `VerticalTabsSidebar` body — O(N) workspace-row render context — on any
/// defaults change, including the minimal-mode toggle (#5732). This model
/// re-checks the stored value on `UserDefaults.didChangeNotification` and
/// mutates `providerId` only when it actually changed, so Observation-tracked
/// readers re-render only on real provider changes.
@MainActor
@Observable
final class ExtensionSidebarProviderSelectionModel {
    static let shared = ExtensionSidebarProviderSelectionModel()

    private(set) var providerId: String

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        providerId = defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
            ?? CmuxExtensionSidebarSelection.defaultProviderId
        // OS notification boundary: UserDefaults has no per-key async API for
        // dotted keys, so observe the coarse didChange signal and filter.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFromDefaults()
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refreshFromDefaults() {
        let next = defaults.string(forKey: CmuxExtensionSidebarSelection.defaultsKey)
            ?? CmuxExtensionSidebarSelection.defaultProviderId
        if providerId != next {
            providerId = next
        }
    }
}

/// Mounts the minimal-mode sidebar titlebar controls strip (sidebar toggle,
/// history, new workspace, notifications). Owns the presentation-mode and
/// titlebar debug-inset subscriptions so toggling minimal mode re-evaluates
/// only this overlay instead of the whole `VerticalTabsSidebar` body with its
/// O(N) workspace-row render context.
struct SidebarMinimalModeTitlebarControlsOverlay: View {
    let observedWindow: NSWindow?
    let notificationStore: TerminalNotificationStore
    let onToggleSidebar: () -> Void
    let onNewTab: () -> Void
    let onFocusHistoryBack: () -> Void
    let onFocusHistoryForward: () -> Void

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
    private var titlebarLeftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
    private var titlebarLeftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var leadingInset: CGFloat {
        CGFloat(MinimalModeTitlebarDebugSettings.clamped(
            titlebarLeftControlsLeadingInset,
            range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
        ))
    }

    private var topPadding: CGFloat {
        // The debug top inset is read from defaults inside the frame helper;
        // the @AppStorage above exists so changing it still re-renders here.
        _ = titlebarLeftControlsTopInset
        guard let observedWindow else {
            return MinimalModeSidebarTitlebarControlsMetrics.topInset
        }
        return minimalModeSidebarTitlebarControlsTopInset(in: observedWindow)
    }

    var body: some View {
        if isMinimalMode {
            HiddenTitlebarSidebarControlsView(
                notificationStore: notificationStore,
                onToggleSidebar: onToggleSidebar,
                onToggleNotifications: { anchorView in
                    AppDelegate.shared?.toggleNotificationsPopover(
                        animated: true,
                        anchorView: anchorView
                    )
                },
                onNewTab: onNewTab,
                onFocusHistoryBack: onFocusHistoryBack,
                onFocusHistoryForward: onFocusHistoryForward
            )
            .padding(.leading, leadingInset)
            .padding(.top, topPadding)
        }
    }
}
