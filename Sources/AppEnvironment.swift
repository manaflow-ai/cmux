import AppKit
import CmuxAppKitSupportUI
import CmuxAuthRuntime
import CmuxBrowser
import CmuxCommandPalette
import CmuxCommandPaletteUI
import CmuxPanes
import CmuxControlSocket
import CmuxWindowing
import CmuxNotifications
import CmuxTerminalCore
import CmuxTerminal
import CmuxSettings
import CmuxSettingsUI
import CmuxShortcuts
import CmuxUpdater
import CmuxWorkspaces
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXAgentLaunch
import CoreServices
import UserNotifications
import WebKit
import Combine
import CmuxFoundation
import CmuxSidebar
#if DEBUG
import CmuxTestSupport
#endif

/// Process-lifetime service holder extracted from `AppDelegate` (Wave 1 of the
/// `AppDelegate.shared` de-singletonization).
///
/// `AppEnvironment` is a focused composition-root holder for the service objects
/// whose lifetime is the whole process (not per-window, not per-session). It is
/// deliberately *not* a god: it stores the service objects and nothing else, and
/// the members keep the exact names, types, optionality, and isolation they had
/// as stored properties on `AppDelegate`, so migrating a call site is a literal
/// `AppDelegate.shared.notificationStore` → `environment.notificationStore`
/// rewrite.
///
/// The single instance is owned by `AppDelegate` (`AppDelegate.environment`),
/// constructed once during app init, and injected into the per-window SwiftUI
/// tree via `.environment(\.appEnvironment, …)` (see `AppEnvironmentKey.swift`).
/// `AppDelegate` keeps computed forwarders for each moved member so the not-yet-
/// migrated `AppDelegate.shared.X` call sites continue to resolve to this same
/// instance during the migration.
///
/// ## Isolation
///
/// `@MainActor` because every service here is created and mutated on the main
/// actor alongside `AppDelegate`. The sole exception is
/// ``accessibilityWindowCache``, which stays `nonisolated(unsafe)` exactly as it
/// was on `AppDelegate`: the `NSApplication` accessibility swizzle reaches it
/// from a `nonisolated` `@objc` context (guarded by `Thread.isMainThread` at the
/// call site), and the existential is non-Sendable.
@MainActor
final class AppEnvironment {
    /// The single `TerminalNotificationStore` owned by the `cmuxApp`
    /// `@StateObject`; recorded here (weakly) at `configure(...)` so the
    /// composition-root forwarders resolve to that instance. Weak, matching the
    /// former `AppDelegate.notificationStore`.
    weak var notificationStore: TerminalNotificationStore?

    /// Coordinates remote tmux (`ssh … tmux -CC`) mirroring; composition-root owned.
    let remoteTmuxController = RemoteTmuxController()

    /// The auth graph, injected once via `AppDelegate.configure(...)` at app
    /// startup. Late-bound (`nil` until configured), matching the former
    /// `private(set) var auth` on `AppDelegate`; the read-only contract is kept
    /// by `AppDelegate` exposing only a getter forwarder.
    var auth: MacAuthComposition?

    /// Owns the inline VS Code `serve-web` process lifecycle
    /// (``VSCodeServeWebController``, CmuxWorkspaces); composition-root owned.
    let vscodeServeWebController = VSCodeServeWebController()

    /// Per-pane runaway-memory guardrail (replaces the former
    /// `PaneMemoryGuardrail.shared` singleton). Read by `ContentView` for the
    /// warning banner.
    let paneMemoryGuardrail = PaneMemoryGuardrailService(
        sampleProvider: PaneMemorySampleProvider(),
        settings: PaneMemoryGuardrailSettings()
    )

    /// The app's settings dependency container, handed over by `cmuxApp` via
    /// `AppDelegate.configure(...)` before any main window is created. Late-bound
    /// (`var` optional), matching the former `AppDelegate.settingsRuntime`.
    var settingsRuntime: SettingsRuntime?

    /// Update-pill / Sparkle update log store; composition-root owned.
    let updateLog = UpdateLogStore()

    /// Keyboard-focus diagnostics log store; composition-root owned.
    let focusLog = FocusLogStore()

    /// Accessibility window-hierarchy cache (CmuxWindowing); composition-root
    /// owned. The `NSApplication` AX swizzle forwards to it behind
    /// ``AccessibilityWindowCaching``.
    /// `nonisolated(unsafe)`: the existential is non-Sendable, but it is only
    /// touched from the main-actor AX swizzle path (callers hold it on main),
    /// matching the other non-Sendable composition-root members.
    nonisolated(unsafe) let accessibilityWindowCache: any AccessibilityWindowCaching = AccessibilityWindowCache()

    #if DEBUG
    /// Debug-only registry mapping each mounted sidebar's window id to its live
    /// `SidebarDragState`. Composition-root owned; injected into the sidebar (via
    /// `\.sidebarDragStateRegistry`) and the `debug.sidebar.simulate_drag` reader.
    let sidebarDragStateRegistry = SidebarDragStateRegistry()

    /// DEBUG main-run-loop stall probe (CmuxTestSupport); composition-root owned,
    /// injected behind ``RunLoopStallMonitoring`` to retire the former
    /// `CmuxMainRunLoopStallMonitor.shared` singleton.
    let runLoopStallMonitor: any RunLoopStallMonitoring = CmuxMainRunLoopStallMonitor()

    /// DEBUG main-thread turn profiler (CmuxTestSupport); composition-root owned,
    /// injected behind ``MainThreadTurnProfiling``. Installed as
    /// `CmuxTypingTiming.turnProfiler` in `applicationDidFinishLaunching` so the
    /// typing probe's `logDuration` forwards to this instance, retiring the former
    /// `CmuxMainThreadTurnProfiler.shared` singleton.
    let mainThreadTurnProfiler: any MainThreadTurnProfiling = CmuxMainThreadTurnProfiler()
    #endif

    init() {}
}
