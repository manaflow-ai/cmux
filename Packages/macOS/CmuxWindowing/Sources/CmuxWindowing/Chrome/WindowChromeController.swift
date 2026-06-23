public import AppKit
public import CoreGraphics
public import Foundation
internal import Observation
public import CmuxSettings

/// Owns the main-window custom-chrome state and its pure logic, extracted from
/// `ContentView`.
///
/// State previously held as `@State`/`@StateObject` on `ContentView`:
/// `titlebarText`, `titlebarThemeGeneration`, `isFullScreen`, `observedWindow`,
/// `sidebarWidth`, the AppKit-reported `titlebarPadding`/`hostingSafeAreaTop`,
/// and the four minimal-mode titlebar debug insets (whose Defaults keys now live
/// in `CmuxSettings.MinimalModeTitlebarInsetSettings`). The injected
/// titlebar-controls view model and the live `NSWindow` chrome install stay
/// app-side behind `WindowChromeHosting`; this controller owns the state and the
/// state-only logic.
///
/// Isolation design: `@MainActor @Observable`. Every mutator originates on the
/// main actor (SwiftUI body, the AppKit `WindowAccessor`, fullscreen
/// notifications, the resizer drag handlers). Co-locating the state with its
/// callers turns every cross-boundary call into a plain main-actor call instead
/// of an actor hop, the same ruling reached for the socket server and
/// `CmuxSidebarGit`. SwiftUI observes the published properties through
/// Observation.
@MainActor
@Observable
public final class WindowChromeController {
    /// Fake-titlebar text for the selected workspace.
    public var titlebarText: String = ""

    /// Monotonic generation bumped to force a titlebar/background theme refresh.
    public var titlebarThemeGeneration: UInt64 = 0

    /// Whether the observed window is in native fullscreen.
    public var isFullScreen: Bool = false

    /// The `NSWindow` this content view is hosted in, once the accessor reports it.
    public var observedWindow: NSWindow?

    /// Current left-sidebar width in points.
    public var sidebarWidth: CGFloat

    /// Native titlebar inset reported by AppKit. Standard mode follows cmux's
    /// visual chrome; minimal `WindowGroup` hosts can still need the reported safe
    /// area cancelled.
    public var titlebarPadding: CGFloat = WindowChromeLayoutMetrics.defaultTitlebarHeight

    /// SwiftUI `WindowGroup` windows can still report a titlebar safe area;
    /// manually created main windows report zero.
    public var hostingSafeAreaTop: CGFloat = 0

    /// Leading inset of the custom titlebar, fed by the AppKit inset reader.
    public var titlebarLeadingInset: CGFloat = 12

    private let titlebarTextCoalescer = WindowChromeTitlebarTextCoalescer(delay: 1.0 / 30.0)

    private weak var host: (any WindowChromeHosting)?

    /// Creates the controller seeded with the default sidebar width.
    /// - Parameter sidebarWidth: initial sidebar width (the app seeds the
    ///   persisted/default value).
    public init(sidebarWidth: CGFloat) {
        self.sidebarWidth = sidebarWidth
    }

    /// Attaches the app-side host seam. Called once from `ContentView.onAppear`.
    public func attach(host: any WindowChromeHosting) {
        self.host = host
    }

    // MARK: - Minimal-mode titlebar debug insets

    /// Resolved snapshot of the four minimal-mode titlebar debug insets, read
    /// from the standard defaults via the `CmuxSettings` key namespace.
    public var titlebarDebugChromeSnapshot: MinimalModeTitlebarInsetSnapshot {
        MinimalModeTitlebarInsetSnapshot(
            leftControlsLeadingInset: Double(MinimalModeTitlebarInsetSettings.leftControlsLeadingInset()),
            leftControlsTopInset: Double(MinimalModeTitlebarInsetSettings.leftControlsTopInset()),
            trafficLightTabBarLeadingInset: Double(MinimalModeTitlebarInsetSettings.trafficLightTabBarLeadingInset()),
            trafficLightTitlebarLeadingInset: Double(MinimalModeTitlebarInsetSettings.trafficLightTitlebarLeadingInset())
        )
    }

    /// Base leading inset for the custom-titlebar inset reader.
    public var trafficLightTitlebarLeadingInset: CGFloat {
        MinimalModeTitlebarInsetSettings.trafficLightTitlebarLeadingInset()
    }

    // MARK: - Titlebar text

    /// Updates `titlebarText` from the host's resolved selected-workspace title.
    public func updateTitlebarText() {
        guard let title = host?.resolvedTitlebarText() else {
            if !titlebarText.isEmpty {
                titlebarText = ""
            }
            return
        }
        if titlebarText != title {
            titlebarText = title
        }
    }

    /// Coalesces a titlebar-text refresh into one update per ~1/30s burst.
    public func scheduleTitlebarTextRefresh() {
        titlebarTextCoalescer.signal { [weak self] in
            self?.updateTitlebarText()
        }
    }

    // MARK: - Titlebar theme

    /// Bumps the theme generation and emits the optional background-theme log
    /// line. Drives `WindowAppearanceSnapshot` recomputation via Observation.
    public func scheduleTitlebarThemeRefresh(
        reason: String,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousGeneration = titlebarThemeGeneration
        titlebarThemeGeneration &+= 1
        guard let host, host.backgroundLogEnabled else { return }
        let eventLabel = backgroundEventId.map(String.init) ?? "nil"
        let sourceLabel = backgroundSource ?? "nil"
        let payloadLabel = notificationPayloadHex ?? "nil"
        host.logBackground(
            "titlebar theme refresh scheduled reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousGeneration=\(previousGeneration) generation=\(titlebarThemeGeneration) \(host.backgroundThemeLogContext())"
        )
    }

    /// Per-workspace gated theme refresh: only refreshes when `workspaceId` is the
    /// selected workspace, otherwise logs a skip line.
    public func scheduleTitlebarThemeRefreshFromWorkspace(
        workspaceId: UUID,
        reason: String,
        backgroundEventId: UInt64?,
        backgroundSource: String?,
        notificationPayloadHex: String?
    ) {
        guard host?.selectedWorkspaceId == workspaceId else {
            guard let host, host.backgroundLogEnabled else { return }
            host.logBackground(
                "titlebar theme refresh skipped workspace=\(workspaceId.uuidString) selected=\(host.selectedWorkspaceId?.uuidString ?? "nil") reason=\(reason)"
            )
            return
        }
        scheduleTitlebarThemeRefresh(
            reason: reason,
            backgroundEventId: backgroundEventId,
            backgroundSource: backgroundSource,
            notificationPayloadHex: notificationPayloadHex
        )
    }

    // MARK: - Window chrome metrics

    /// Re-reads the AppKit titlebar height + safe-area top for `window` and
    /// publishes them (debounced through the next runloop tick to avoid mutating
    /// during layout), matching the legacy `refreshWindowChromeMetrics`.
    public func refreshWindowChromeMetrics(for window: NSWindow) {
        let computedTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let nextPadding = WindowChromeLayoutMetrics.clampedTitlebarHeight(computedTitlebarHeight)
        let nextSafeAreaTop = max(0, window.contentView?.safeAreaInsets.top ?? 0)
        if abs(titlebarPadding - nextPadding) > 0.5 {
            DispatchQueue.main.async { [weak self] in
                self?.titlebarPadding = nextPadding
            }
        }
        if abs(hostingSafeAreaTop - nextSafeAreaTop) > 0.5 {
            DispatchQueue.main.async { [weak self] in
                self?.hostingSafeAreaTop = nextSafeAreaTop
            }
        }
    }

    // MARK: - Portal sync

    /// Forwards portal geometry synchronization to the host, scoped to the
    /// observed window when present.
    public func schedulePortalGeometrySynchronize() {
        host?.schedulePortalGeometrySynchronize(for: observedWindow)
    }

    /// Applies titlebar-debug chrome changes: re-decorate the observed window and
    /// re-sync the traffic-light tab-bar inset.
    public func applyTitlebarDebugChromeChange(isMinimalMode: Bool, isSidebarVisible: Bool) {
        if let observedWindow {
            host?.applyWindowDecorations(to: observedWindow)
        }
        syncTrafficLightInset(isMinimalMode: isMinimalMode, isSidebarVisible: isSidebarVisible)
    }

    /// Syncs the workspace tab-bar leading inset for the traffic lights, applying
    /// the debug inset only in minimal mode with a hidden sidebar and no
    /// fullscreen.
    public func syncTrafficLightInset(isMinimalMode: Bool, isSidebarVisible: Bool) {
        let inset: CGFloat = (isMinimalMode && !isSidebarVisible && !isFullScreen)
            ? CGFloat(titlebarDebugChromeSnapshot.trafficLightTabBarLeadingInset)
            : 0
        host?.syncWorkspaceTabBarLeadingInset(inset)
    }
}
