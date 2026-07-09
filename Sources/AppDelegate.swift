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
import CmuxRemoteWorkspace
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
import CoreGraphics
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation
import CmuxSidebar
#if DEBUG
import CmuxTestSupport
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation, NSMenuDelegate, CmuxConfigStoreReloadEnvironment, ExternalOpenIntentHosting, WindowLifecycleHosting, AppMenuHosting {
    nonisolated(unsafe) static var shared: AppDelegate?
    /// Process-lifetime service holder (Wave 1 of the `AppDelegate.shared`
    /// de-singletonization). Owns the service objects whose lifetime is the whole
    /// process; constructed once here at the composition root and injected into
    /// the per-window SwiftUI tree via `.environment(\.appEnvironment, …)`. The
    /// moved members keep their exact names/types/optionality/isolation, and
    /// `AppDelegate` exposes a computed forwarder for each so the not-yet-migrated
    /// `AppDelegate.shared.X` sites resolve to this same instance.
    /// Immutable `Sendable` value, so Swift can read it safely from nonisolated
    /// paths such as the accessibility-swizzle cache forwarder.
    let environment: AppEnvironment
    /// Stateless control-socket syscall layer (CmuxControlSocket); composition-root owned.
    nonisolated let socketTransport = SocketTransport()
    /// The app-target composition owner for external programmatic control: the
    /// socket-lifecycle ``SocketControlServer``, the ``ControlCommandCoordinator``,
    /// and the ``ControlCommandContext`` conformance. Constructed once at the
    /// composition root (`applicationDidFinishLaunching` calls
    /// ``ensureTerminalControlInstalled()``) so the type no longer self-vivifies a
    /// `static let shared`. This is the injected reference the AppDelegate call
    /// sites use directly; the tail of call sites (cmuxApp, Workspace, the static
    /// focus-allowance methods, the `+Control*Context` seams, tests) still reach
    /// it through the transitional ``TerminalController/shared`` accessor, which
    /// returns this same instance.
    private(set) lazy var terminalControl: TerminalController = {
        let instance = TerminalController.shared
        TerminalController.installCompositionRootInstance(instance)
        instance.attachAppEnvironment(environment)
        return instance
    }()

    /// Resolve + own the ``TerminalController`` composition owner at startup.
    /// Idempotent (the `lazy` runs once); calling it from
    /// `applicationDidFinishLaunching` makes ownership explicit at the
    /// composition root and holds the single instance as ``terminalControl``,
    /// which the AppDelegate call sites use directly. The tail call sites still
    /// reach the same object through the transitional ``TerminalController/shared``
    /// accessor, so there is exactly one instance.
    func ensureTerminalControlInstalled() {
        _ = terminalControl
    }
    /// The app-target composition owner for the recently-closed-item history
    /// store (`ClosedItemHistoryStore`). Constructed once at the composition root
    /// (`applicationDidFinishLaunching` calls
    /// ``ensureClosedItemHistoryInstalled()``) so the type no longer self-vivifies
    /// a `static let shared`. This is the injected reference the AppDelegate call
    /// sites use directly; the tail of call sites (`cmuxApp` history menu,
    /// `Workspace`, `TabManager`) still reach it through the transitional
    /// ``ClosedItemHistoryStore/shared`` accessor, which returns this same
    /// instance.
    private(set) lazy var closedItemHistory: ClosedItemHistoryStore = {
        let instance = ClosedItemHistoryStore.shared
        ClosedItemHistoryStore.installCompositionRootInstance(instance)
        return instance
    }()

    /// Resolve + own the ``ClosedItemHistoryStore`` at startup. Idempotent (the
    /// `lazy` runs once); calling it from `applicationDidFinishLaunching` makes
    /// ownership explicit at the composition root and holds the single instance
    /// as ``closedItemHistory``, which the AppDelegate call sites use directly.
    /// The tail call sites still reach the same object through the transitional
    /// ``ClosedItemHistoryStore/shared`` accessor, so there is exactly one
    /// instance.
    func ensureClosedItemHistoryInstalled() {
        _ = closedItemHistory
    }
    /// Owns the inline VS Code `serve-web` process lifecycle
    /// (``VSCodeServeWebController``, CmuxWorkspaces); composition-root owned so
    /// the type no longer exposes a `static let shared`. Storage moved to
    /// ``AppEnvironment``; this forwarder keeps the not-yet-migrated
    /// `AppDelegate.shared.vscodeServeWebController` sites resolving to it.
    /// `nonisolated` because the stored `let` it replaced was cross-actor
    /// readable (ShortcutRoutingSupport's default-argument closure reads it
    /// from a nonisolated context); the body performs that same immutable read
    /// through the `nonisolated(unsafe)` `environment` reference.
    nonisolated var vscodeServeWebController: VSCodeServeWebController { environment.vscodeServeWebController }
    #if DEBUG
    /// DEBUG main-run-loop stall probe (CmuxTestSupport). Storage moved to
    /// ``AppEnvironment``; forwarder preserved for not-yet-migrated sites.
    var runLoopStallMonitor: any RunLoopStallMonitoring { environment.runLoopStallMonitor }
    /// DEBUG main-thread turn profiler (CmuxTestSupport). Storage moved to
    /// ``AppEnvironment``; forwarder preserved for not-yet-migrated sites.
    var mainThreadTurnProfiler: any MainThreadTurnProfiling { environment.mainThreadTurnProfiler }
    #endif
    /// Owns the About Titlebar Debug subsystem (CmuxAppKitSupportUI); composition-root
    /// owned and created lazily so the window-decoration seam can point back at `self`.
    /// The Debug Window Controls panel's content is app-coupled (it opens other
    /// app-target debug windows and reads app-target settings), so its content view is
    /// injected from the app target here while the window/lifecycle shell lives in the package.
    #if DEBUG
    lazy var debugWindowsCoordinator = DebugWindowsCoordinator(
        decorator: self,
        aboutPanelStrings: self.debugWindowControlsContentProvider.aboutPanelStrings,
        acknowledgmentsStrings: self.debugWindowControlsContentProvider.acknowledgmentsStrings,
        browserDebugContext: self,
        tabBarBackdropLabContentProvider: { NSHostingView(rootView: TabBarBackdropLabView(inputs: self.debugWindowControlsContentProvider.tabBarBackdropLabInputs)) },
        sidebarDebugContentProvider: {
            NSHostingView(rootView: SidebarDebugView(
                accentColor: { cmuxAccentColor() },
                indicatorStyleDisplayName: { $0.displayName }
            ))
        },
        debugWindowControlsContentProvider: { self.debugWindowControlsContentProvider.debugWindowControlsContentView },
        menuBarExtraDebugRefresh: { AppDelegate.shared?.refreshMenuBarExtraForDebug() },
        backgroundDebugContentProvider: {
            NSHostingView(rootView: BackgroundDebugView(applyGlassTint: { tintColor in
                let window: NSWindow? = {
                    if let key = NSApp.keyWindow,
                       let raw = key.identifier?.rawValue,
                       MainTerminalWindowIdentifier.matches(rawIdentifier: raw) {
                        return key
                    }
                    return NSApp.windows.first(where: {
                        guard let raw = $0.identifier?.rawValue else { return false }
                        return MainTerminalWindowIdentifier.matches(rawIdentifier: raw)
                    })
                }()
                guard let window else { return }
                AppWindowChromeComposition().backdropController.updateGlassTint(to: window, color: tintColor)
            }))
        },
        fileExplorerStyleDebugContentProvider: {
            NSHostingView(rootView: FileExplorerStyleDebugView(
                options: FileExplorerStyle.allCases.map { style in
                    FileExplorerStyleDebugOption(
                        rawValue: style.rawValue,
                        label: style.label,
                        description: style.fileExplorerStyleDebugDescription,
                        rowHeight: style.rowHeight,
                        indentation: style.indentation,
                        iconSize: style.iconSize
                    )
                },
                notifyStyleDidChange: {
                    NotificationCenter.default.post(name: .fileExplorerStyleDidChange, object: nil)
                }
            ))
        },
        startupAppearanceDebugWindowTitle: String(
            localized: "debug.startupAppearance.window.title",
            defaultValue: "Startup Appearance Debug"
        ),
        startupAppearanceDebugContentProvider: {
            NSHostingView(rootView: StartupAppearanceDebugView(
                reloading: StartupAppearanceDebugReloader(),
                strings: self.debugWindowControlsContentProvider.startupAppearanceDebugStrings
            ))
        },
        openBonsplitTabBarDebug: { BonsplitTabBarDebugWindowController.shared.show() },
        openDevWindowDisplayDebug: { DevWindowDisplayDebugWindowController.shared.show() },
        openFeedPreview: { FeedPreviewWindowController.shared.show() },
        openFeedTextEditorDebug: { FeedTextEditorDebugWindowController.shared.show() },
        openFeedButtonStyleDebug: { FeedButtonStyleDebugWindowController.shared.show() },
        openTitlebarLayoutDebug: { TitlebarLayoutDebugWindowController.shared.show() },
        openPDFPreviewChromeDebug: { PDFPreviewChromeDebugWindowController.shared.show() }
    )
    #else
    lazy var debugWindowsCoordinator = DebugWindowsCoordinator(
        decorator: self,
        aboutPanelStrings: self.debugWindowControlsContentProvider.aboutPanelStrings,
        acknowledgmentsStrings: self.debugWindowControlsContentProvider.acknowledgmentsStrings,
        browserDebugContext: self,
        tabBarBackdropLabContentProvider: { NSHostingView(rootView: TabBarBackdropLabView(inputs: self.debugWindowControlsContentProvider.tabBarBackdropLabInputs)) },
        sidebarDebugContentProvider: {
            NSHostingView(rootView: SidebarDebugView(
                accentColor: { cmuxAccentColor() },
                indicatorStyleDisplayName: { $0.displayName }
            ))
        }
    )
    #endif
    /// About Titlebar Debug options store, applied by the About/Acknowledgments windows.
    var aboutTitlebarDebugStore: AboutTitlebarDebugStore { debugWindowsCoordinator.aboutTitlebarStore }
    /// App-target owner of the About / debug-window content builders that were
    /// formerly an all-static namespace cluster on this `AppDelegate` singleton.
    /// Holds the live ``DebugWindowsCoordinator`` (resolved lazily so the
    /// construction order between this provider and `debugWindowsCoordinator`
    /// stays acyclic; the closure preserves the former
    /// `AppDelegate.shared?.debugWindowsCoordinator` no-op-if-absent semantics)
    /// and `UserDefaults.standard`. The coordinator init reads its localized
    /// strings/inputs and the Debug Window Controls content view from this
    /// instance instead of the retired `AppDelegate.foo` statics.
    private var _debugWindowControlsContentProvider: DebugWindowControlsContentProvider?
    var debugWindowControlsContentProvider: DebugWindowControlsContentProvider {
        if let existing = _debugWindowControlsContentProvider { return existing }
        let provider = DebugWindowControlsContentProvider(
            debugWindowsCoordinator: { [weak self] in self?.debugWindowsCoordinator },
            defaults: .standard
        )
        _debugWindowControlsContentProvider = provider
        return provider
    }

    /// Coordinates remote tmux (`ssh … tmux -CC`) mirroring. Storage moved to
    /// ``AppEnvironment``; this forwarder keeps the not-yet-migrated
    /// `AppDelegate.shared.remoteTmuxController` sites resolving to it.
    var remoteTmuxController: RemoteTmuxController { environment.remoteTmuxController }
    private static let reloadConfigurationMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.cmux.reloadConfiguration")

    private static let cachedIsRunningUnderXCTest = detectRunningUnderXCTest(ProcessInfo.processInfo.environment)
    // Internal (not private) so the `ApplicationActivationHost` conformance in
    // `AppDelegate+ApplicationActivationHost.swift` can witness it.
    var isRunningUnderXCTestCached: Bool {
        Self.cachedIsRunningUnderXCTest
    }
    private var cmuxThemePreviewReloadGeneration = 0
    private var cmuxThemePreviewReloadWorkItem: DispatchWorkItem?

    private static func detectRunningUnderXCTest(_ env: [String: String]) -> Bool {
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if env["XCInjectBundle"] != nil { return true }
        if env["XCInjectBundleInto"] != nil { return true }
        if env["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if env.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) { return true }
        return false
    }

    private func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        // On some macOS/Xcode setups, the app-under-test process doesn't get
        // `XCTestConfigurationFilePath`. Use a broader set of signals so UI tests
        // can reliably skip heavyweight startup work and bring up a window.
        Self.detectRunningUnderXCTest(env)
    }

    /// An ephemeral, resolved view of one registered main window.
    ///
    /// This is the de-aggregation endgame (owner ruling 2026-06-18: per-window
    /// state is domain-owned and `WindowID`-keyed; the former
    /// `MainWindowContext` *class* — a stored per-window aggregate fusing tabs,
    /// sidebar, focus, file-explorer, config and `NSWindow` — is REJECTED). The
    /// last live per-window fields it still held (`tabManager`,
    /// `keyboardFocusCoordinator`, the `NSWindow` handle, and the sidebar /
    /// sidebar-selection / file-explorer / config slices) now live in one
    /// ``WindowContext`` per window, indexed by ``windowRegistry`` and held
    /// (weakly) by the per-window `MainWindowController`; the `NSWindow` handle
    /// stays in ``windowCoordinator``.
    ///
    /// `RegisteredMainWindow` is NOT stored anywhere and owns no state: it is a
    /// value snapshot built on demand by the resolver methods
    /// (``registeredMainWindow(for:)`` and friends) by reading the per-domain
    /// stores for one ``WindowID``. Callers read `.windowId`, `.tabManager`,
    /// `.keyboardFocusCoordinator`, and `.window` exactly as they read the old
    /// class's stored properties, so the call sites stay byte-identical; the
    /// difference is that the value is reconstructed each lookup rather than
    /// mutated in place (window identity reindexing is now owned by
    /// ``windowCoordinator``, so no per-context `weak var window` mutation is
    /// needed). Mirrors the existing ``ScriptableMainWindowState`` value handle.
    struct RegisteredMainWindow {
        let windowId: UUID
        let tabManager: TabManager
        let keyboardFocusCoordinator: MainWindowFocusController
        /// The live `NSWindow` for this window resolved at build time (via
        /// ``windowCoordinator`` then the identifier fallback), or `nil` when the
        /// window is not currently realized. Faithfully replaces the old class's
        /// `weak var window` read, which was likewise the last-reindexed handle.
        let window: NSWindow?
    }

    @MainActor
    private final class NewWorkspaceContextMenuActionBox: NSObject {
        let windowId: UUID
        let action: CmuxResolvedConfigAction

        init(windowId: UUID, action: CmuxResolvedConfigAction) {
            self.windowId = windowId
            self.action = action
        }
    }

    private final class MainWindowController: NSWindowController, NSWindowDelegate {
        var onClose: (() -> Void)?
        var shouldClose: (() -> Bool)?

        /// This window's per-window state. Held weakly: the strong owner is
        /// ``AppDelegate/windowRegistry`` (exactly replacing the old per-slice
        /// dictionaries' strong ownership), so the context's lifetime is
        /// unchanged and the controller only expresses the per-window
        /// association. Set after `registerMainWindow` seeds the context.
        weak var windowContext: WindowContext?

        #if DEBUG
        private func logWindowEvent(_ event: String, notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            let id = window.identifier?.rawValue ?? "<nil>"
            cmuxDebugLog(
                "mainWindow.delegate.\(event) window=\(id) visible=\(window.isVisible ? 1 : 0) mini=\(window.isMiniaturized ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
            )
        }
        #endif

        func windowWillClose(_ notification: Notification) {
            onClose?()
        }

        #if DEBUG
        func windowDidDeminiaturize(_ notification: Notification) {
            logWindowEvent("didDeminiaturize", notification: notification)
        }

        func windowDidMiniaturize(_ notification: Notification) {
            logWindowEvent("didMiniaturize", notification: notification)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            logWindowEvent("didBecomeKey", notification: notification)
        }

        func windowDidResignKey(_ notification: Notification) {
            logWindowEvent("didResignKey", notification: notification)
        }

        func windowDidBecomeMain(_ notification: Notification) {
            logWindowEvent("didBecomeMain", notification: notification)
        }

        func windowDidResignMain(_ notification: Notification) {
            logWindowEvent("didResignMain", notification: notification)
        }
        #endif

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let shouldClose = shouldClose?() ?? true
            if shouldClose {
                WebViewInspectorTeardown.closeAllInspectors(in: sender)
            }
            return shouldClose
        }

        func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
            guard window is CmuxMainWindow else { return newFrame }
            return CmuxMainWindow.standardFrame(forDefaultFrame: newFrame)
        }
    }

    struct ScriptableMainWindowState {
        let windowId: UUID
        let tabManager: TabManager
        let window: NSWindow?
    }

    /// Lifted to ``CmuxWindowing/SessionDisplayGeometry``; aliased so existing
    /// `AppDelegate.SessionDisplayGeometry` references stay source-identical.
    typealias SessionDisplayGeometry = CmuxWindowing.SessionDisplayGeometry

    struct PersistedWindowGeometry: Codable, Sendable, WindowGeometryPersisting {
        let version: Int
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    nonisolated static let persistedWindowGeometrySchemaVersion = 2
    private nonisolated static let persistedWindowGeometryDefaultsKey = "cmux.session.lastWindowGeometry.v2"
#if DEBUG
    nonisolated static var debugPersistedWindowGeometryDefaultsKey: String { persistedWindowGeometryDefaultsKey }
#endif
    private nonisolated static let legacyPersistedWindowGeometryDefaultsKeys = [
        "cmux.session.lastWindowGeometry.v1"
    ]

    /// `UserDefaults`-backed primary-window geometry persistence, lifted to
    /// ``CmuxWorkspaces/WindowGeometryStore``. The FROZEN defaults key, legacy
    /// keys, and schema version are passed in so the wire format stays
    /// app-owned. A pure value, so a shared constant, not per-call.
    private nonisolated static let windowGeometryStore = WindowGeometryStore<PersistedWindowGeometry>(
        schemaVersion: persistedWindowGeometrySchemaVersion,
        defaultsKey: persistedWindowGeometryDefaultsKey,
        legacyDefaultsKeys: legacyPersistedWindowGeometryDefaultsKeys
    )

    var tabManager: TabManager? {
        get { environment.mainWindowRouter.activeTabManager }
        set { environment.mainWindowRouter.activeTabManager = newValue }
    }
    /// The single `TerminalNotificationStore` (owned by the `cmuxApp`
    /// `@StateObject`). Storage moved to ``AppEnvironment``, which holds it
    /// weakly exactly as the former `weak var` here did; this get/set forwarder
    /// keeps the not-yet-migrated `AppDelegate.shared.notificationStore` sites
    /// (and the `configure(...)` write) resolving to it.
    var notificationStore: TerminalNotificationStore? {
        get { environment.notificationStore }
        set { environment.notificationStore = newValue }
    }
    var sidebarState: SidebarState? {
        get { environment.mainWindowRouter.activeSidebarState }
        set { environment.mainWindowRouter.activeSidebarState = newValue }
    }

    /// Notification jump/open navigation, extracted into `CmuxNotifications`.
    /// `AppDelegate` is the composition root: it conforms to every seam (see
    /// `AppDelegate+NotificationNavSeams.swift`) and injects itself. Built lazily
    /// because the seams read late-bound state (`notificationStore`,
    /// `mainWindowContexts`) that is `nil` until startup wiring completes; the
    /// seam contracts already degrade to empty/no-op when that state is absent.
    /// Performs notification click actions (currently reveal-in-Finder). Both the
    /// path-resolution logic and the `NSWorkspace`/`FileManager` side effect now
    /// live in the package (`NotificationClickPerformer` over the injected
    /// `SystemFinderRevealer`); `AppDelegate` only injects the concrete revealer.
    /// Shared by the navigation coordinator and the delivery coordinator.
    /// Weak-owner adapter that satisfies every notification-nav seam by
    /// forwarding to `AppDelegate` helpers. The coordinator and click performer
    /// strong-ref this adapter; the adapter weak-refs `AppDelegate`, so there is
    /// no `AppDelegate → coordinator → AppDelegate` retain cycle (which would pin
    /// the app-host test instance). See `AppDelegate+NotificationNavSeams.swift`.
    lazy var notificationNavSeams = NotificationNavSeamAdapter(owner: self)

    lazy var notificationClickPerformer = NotificationClickPerformer(finder: SystemFinderRevealer())

    /// Weak-owner adapter that satisfies the open-routing seams
    /// (``NotificationOpenRoutingHosting`` + ``NotificationOpenRoutingTracing``)
    /// by forwarding to `AppDelegate` helpers. Mirrors ``notificationNavSeams``:
    /// the coordinator strong-refs this adapter; the adapter weak-refs
    /// `AppDelegate`. See `AppDelegate+NotificationOpenRoutingSeams.swift`.
    lazy var notificationOpenRoutingSeams = NotificationOpenRoutingSeamAdapter(owner: self)

    /// The extracted notification-open routing decision skeleton. The window
    /// mechanics and `#if DEBUG` UI-test recorders stay app-side behind the two
    /// seams; this coordinator only decides which route to take.
    lazy var notificationOpenRoutingCoordinator = NotificationOpenRoutingCoordinator(
        host: notificationOpenRoutingSeams,
        tracing: notificationOpenRoutingSeams
    )

    /// Weak-owner adapter that satisfies the activation-unread seams
    /// (``NotificationActivationUnreadHosting`` +
    /// ``NotificationActivationFlashing``) by forwarding to the live
    /// `notificationStore` / `tabManager`. Mirrors ``notificationOpenRoutingSeams``:
    /// the reconciler strong-refs this adapter; the adapter weak-refs
    /// `AppDelegate`. See `AppDelegate+NotificationActivationSeams.swift`.
    lazy var notificationActivationSeams = NotificationActivationSeamAdapter(owner: self)

    /// The extracted activation-driven unread-reconciliation decision. The live
    /// store/tab/workspace effects stay app-side behind the two seams; this
    /// reconciler only decides whether to flash the focused pane and mark read.
    lazy var notificationActivationUnreadReconciler = NotificationActivationUnreadReconciler(
        store: notificationActivationSeams,
        flashing: notificationActivationSeams
    )

    lazy var notificationNavigation: NotificationNavigationCoordinator =
        NotificationNavigationCoordinator(
            store: notificationNavSeams,
            windows: notificationNavSeams,
            unreadTargeting: notificationNavSeams,
            openRouting: notificationNavSeams,
            clickRouting: notificationClickPerformer,
            focusedResolving: notificationNavSeams,
            popoverPresenting: notificationNavSeams,
            // Route the focused-mark jump through `AppDelegate.jumpToLatestUnread`
            // so its `#if DEBUG` `jumpUnreadInvoked` recorder and nil-store guard
            // still fire exactly as before; map the resolved notification back to
            // its id for the package boundary.
            focusedJump: { [unowned self] excludedNotificationId, excludedWorkspaceId in
                self.jumpToLatestUnread(
                    excludingNotificationId: excludedNotificationId,
                    excludingWorkspaceId: excludedWorkspaceId
                )?.id
            }
        )

    /// Routes notification-feed focus/send-text requests into V2 socket commands,
    /// extracted into `CmuxNotifications`. The router builds the typed JSON-RPC
    /// lines; the app-side `FeedRequestSocketAdapter` forwards each line to
    /// `TerminalController.shared.handleSocketLine(_:)` (a singleton the package
    /// must not import). The `@objc handleFeedRequest*` selector methods stay on
    /// `AppDelegate` and forward their parsed `userInfo` here.
    lazy var feedRequestRouter = FeedRequestRouter(socketInvoking: FeedRequestSocketAdapter())

    /// OS notification delivery/response coordination, extracted into
    /// `CmuxNotifications`. The app target injects the concrete
    /// `UNUserNotificationCenter`, terminal identifiers from
    /// `TerminalNotificationStore`, localized action titles, and the weak-owner
    /// Feed/app activation seam.
    lazy var notificationDeliverySeams = NotificationDeliverySeamAdapter(owner: self)

    lazy var notificationDelivery = NotificationDeliveryCoordinator(
        center: UNUserNotificationCenter.current(),
        terminalNavigation: notificationNavigation,
        feedReplying: notificationDeliverySeams,
        applicationActivation: notificationDeliverySeams,
        terminalIdentifiers: TerminalNotificationDeliveryIdentifiers(
            categoryIdentifier: TerminalNotificationStore.categoryIdentifier,
            showActionIdentifier: TerminalNotificationStore.actionShowIdentifier
        ),
        actionTitles: notificationDeliveryActionTitles
    )

    private var notificationDeliveryActionTitles: NotificationDeliveryActionTitles {
        NotificationDeliveryActionTitles(
            show: String(
                localized: "terminal.notification.action.show",
                defaultValue: "Show"
            ),
            feedPermissionAllowOnce: String(
                localized: "feed.notification.permission.allowOnce",
                defaultValue: "Allow Once"
            ),
            feedPermissionAlways: String(
                localized: "feed.notification.permission.always",
                defaultValue: "Always"
            ),
            feedPermissionAll: String(
                localized: "feed.notification.permission.all",
                defaultValue: "All tools"
            ),
            feedPermissionDeny: String(
                localized: "feed.notification.permission.deny",
                defaultValue: "Deny"
            ),
            feedExitPlanUltraplan: String(
                localized: "feed.notification.exitPlan.ultraplan",
                defaultValue: "Ultraplan"
            ),
            feedExitPlanManual: String(
                localized: "feed.notification.exitPlan.manual",
                defaultValue: "Manual"
            ),
            feedExitPlanAutoAccept: String(
                localized: "feed.notification.exitPlan.autoAccept",
                defaultValue: "Auto"
            ),
            feedQuestionReply: String(
                localized: "feed.notification.question.reply",
                defaultValue: "Reply"
            )
        )
    }
    // The open-routing trio's decision skeleton (`openNotification` /
    // `openNotificationInContext` / `openNotificationFallback`) now lives in
    // `NotificationOpenRoutingCoordinator`; the three `AppDelegate` methods are
    // thin forwarders into it (reached through the open-routing seam `openRouted`
    // / `openInWindow` / `openInActiveWindowFallback`). The ~15 branch-specific
    // `#if DEBUG` jump-unread UI-test recorder payloads stay app-side behind
    // `NotificationOpenRoutingTracing`, and the window mechanics behind
    // `NotificationOpenRoutingHosting` (see
    // `AppDelegate+NotificationOpenRoutingSeams.swift`): the coordinator calls one
    // tracing hook per legacy recorder call site in the original order, and each
    // app-side witness reproduces its `#if DEBUG` body verbatim, so payloads and
    // ordering the jump-unread XCUITest asserts on are byte-identical. The
    // navigation coordinator's `onDidFocusForJumpUnread` hook is left unwired
    // (wiring it would double-record). The recorder-FREE members of the open/click
    // cluster moved earlier: the reveal-in-Finder side effect lives in
    // `NotificationClickPerformer` (behind `FinderRevealing`), and the entire
    // focused-mark state machine lives in `FocusedNotificationMarker` (behind
    // `FocusedNotificationResolving`).
    /// The auth graph, injected once via `configure(...)` at app startup.
    /// Storage moved to ``AppEnvironment``; this read-only forwarder preserves
    /// the former `private(set)` contract (the single write in `configure(...)`
    /// assigns `environment.auth` directly).
    var auth: MacAuthComposition? { environment.auth }
    /// Strongly-held observers for every active TabManager. Each observer owns
    /// Combine subscriptions that publish workspace.updated to mobile clients.
    private var mobileWorkspaceListObservers: [ObjectIdentifier: MobileWorkspaceListObserver] = [:]
    private let agentChatTranscriptService = AgentChatTranscriptService()
    /// The app's settings dependency container, handed over by `cmuxApp` via
    /// `configure(...)` before any main window is created. AppKit builds the
    /// main window's `NSHostingView` itself, so it injects this into the
    /// `ContentView` environment so `@LiveSetting` can resolve the stores it
    /// observes inside the sidebar. Storage moved to ``AppEnvironment``; this
    /// get/set forwarder keeps the not-yet-migrated
    /// `AppDelegate.shared.settingsRuntime` sites (and the `configure(...)`
    /// write) resolving to it.
    var settingsRuntime: SettingsRuntime? {
        get { environment.settingsRuntime }
        set { environment.settingsRuntime = newValue }
    }
    var fileExplorerState: FileExplorerState? {
        get { environment.mainWindowRouter.activeFileExplorerState }
        set { environment.mainWindowRouter.activeFileExplorerState = newValue }
    }
    weak var fullscreenControlsViewModel: TitlebarControlsViewModel?
    var sidebarSelectionState: SidebarSelectionState? {
        get { environment.mainWindowRouter.activeSidebarSelectionState }
        set { environment.mainWindowRouter.activeSidebarSelectionState = newValue }
    }
    /// Owns the keyboard-shortcut event decode (layout-character resolution and
    /// numbered-digit/character normalization) in the `CmuxShortcuts` package.
    /// The per-keystroke dispatch stays app-side and reaches the decode through
    /// this one held reference, so the hot path takes a single property access.
    let shortcutCoordinator = ShortcutCoordinator(
        layoutCharacterProvider: KeyboardLayout.character(forKeyCode:modifierFlags:)
    )
    /// The layout-character provider used to decode shortcut events. Forwards to
    /// ``shortcutCoordinator`` so the test seam (`AppDelegateShortcutRoutingTests`
    /// swaps this between a fixed closure and the live default) keeps working
    /// while the state itself is owned by the coordinator.
    var shortcutLayoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? {
        get { shortcutCoordinator.layoutCharacterProvider }
        set { shortcutCoordinator.layoutCharacterProvider = newValue }
    }
    private var workspaceObserver: NSObjectProtocol?
    private var windowKeyObservers: [NSObjectProtocol] = []
    private var shortcutMonitor: Any?
    private var shortcutDefaultsObserver: NSObjectProtocol?
    private var mobileHostSettingsObserver: NSObjectProtocol?
    private var reloadConfigurationMenuItemRefreshScheduled = false
    /// Orchestrates per-window cmux config-store reloads + window-title refresh.
    /// Holds `self` weakly through the environment seam to avoid a retain cycle.
    private lazy var configStoreReloadCoordinator: CmuxConfigStoreReloadCoordinator = {
        CmuxConfigStoreReloadCoordinator(environment: self) { source, storeCount in
#if DEBUG
            cmuxDebugLog("cmuxConfig.reload source=\(source) stores=\(storeCount)")
#endif
        }
    }()
    private var splitButtonTooltipRefreshScheduled = false
    private var didScheduleGhosttyCrashBreadcrumbCheck = false
    // Internal (not private) so the `ApplicationTerminationHost` teardown witness
    // `cancelGhosttyCrashBreadcrumbTask()` in the conformance file can clear it.
    var ghosttyCrashBreadcrumbTask: Task<Void, Never>?
    /// Owns the configured-shortcut chord (two-stroke) state machine. The
    /// per-keystroke dispatch (`handleCustomShortcut` et al.) stays app-side and
    /// reaches the chord state through this one held reference, so the hot path
    /// takes a single property access rather than any new allocation.
    let shortcutChordCoordinator = ShortcutChordCoordinator<ShortcutStroke>()
    /// The chord prefix live for the event currently being dispatched.
    /// Forwards to ``shortcutChordCoordinator`` so every legacy call site reads
    /// and writes the same state, now owned by the coordinator.
    var activeConfiguredShortcutChordPrefixForCurrentEvent: ShortcutStroke? {
        get { shortcutChordCoordinator.activePrefixForCurrentEvent }
        set { shortcutChordCoordinator.activePrefixForCurrentEvent = newValue }
    }
    var shortcutEventFocusContextCache: ShortcutEventFocusContextCache?
    private var ghosttyConfigObserver: NSObjectProtocol?
    private var ghosttyGotoSplitLeftShortcut: StoredShortcut?
    private var ghosttyGotoSplitRightShortcut: StoredShortcut?
    private var ghosttyGotoSplitUpShortcut: StoredShortcut?
    private var ghosttyGotoSplitDownShortcut: StoredShortcut?
#if DEBUG
    /// The resolved Ghostty goto-split trigger shortcut display strings, read by
    /// ``GotoSplitUITestRecorder`` when it captures the initial focus snapshot.
    /// The backing `StoredShortcut`s stay private to the live shortcut-routing
    /// path; this exposes only their display strings to the recorder.
    var ghosttyGotoSplitShortcutDisplayStrings: (left: String, right: String, up: String, down: String) {
        let formatter = ShortcutDisplayFormatter()
        return (
            ghosttyGotoSplitLeftShortcut.map { formatter.displayString($0) } ?? "",
            ghosttyGotoSplitRightShortcut.map { formatter.displayString($0) } ?? "",
            ghosttyGotoSplitUpShortcut.map { formatter.displayString($0) } ?? "",
            ghosttyGotoSplitDownShortcut.map { formatter.displayString($0) } ?? ""
        )
    }
#endif
    /// Tracks which browser panel owns address-bar focus and owns the omnibar
    /// selection-repeat coordinator, both extracted into `CmuxBrowser`. The app
    /// delegate is the composition root: it injects the coordinator's
    /// `NotificationCenter` selection-move sink and debug-trace sink, then
    /// forwards every focus mutation through the tracker (which stops the repeat
    /// whenever focus is cleared or re-pointed). The AppKit/`Workspace`/
    /// `BrowserPanel` decision logic that computes which panel should be focused
    /// stays here; only the tracked state and its repeat coupling live in the
    /// package.
    private lazy var browserOmnibarFocusTracker: BrowserOmnibarFocusTracker = {
        let debugLog: BrowserOmnibarSelectionRepeatCoordinator.DebugLog?
#if DEBUG
        debugLog = { line in cmuxDebugLog(line) }
#else
        debugLog = nil
#endif
        let selectionRepeat = BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: { panelId, delta in
                NotificationCenter.default.post(
                    name: .browserMoveOmnibarSelection,
                    object: panelId,
                    userInfo: ["delta": delta]
                )
            },
            debugLog: debugLog
        )
        return BrowserOmnibarFocusTracker(selectionRepeat: selectionRepeat)
    }()
    /// Records which browser web view owns each window field editor, replacing
    /// the retired `cmuxFieldEditorOwningWebViewAssociationKey` global var + box.
    /// The composition root holds the one instance; the NSWindow first-responder
    /// shim forwards through it.
    let browserFieldEditorOwnershipRegistry = BrowserFieldEditorOwnershipRegistry()
    private var browserAddressBarFocusObserver: NSObjectProtocol?
    private var browserAddressBarBlurObserver: NSObjectProtocol?
    private var browserWebViewFirstResponderObserver: NSObjectProtocol?
    /// Keyboard-focus diagnostics log store. Storage moved to
    /// ``AppEnvironment``; forwarder preserved for not-yet-migrated sites.
    var focusLog: FocusLogStore { environment.focusLog }
    /// Process-wide identity of the workspace currently being sidebar-dragged in
    /// any window. Owned here (the composition root) and injected into every
    /// window's `SidebarDragState` so cross-window drops resolve a single drag.
    // TODO(de-singletonize): move SidebarWorkspaceDragRegistry off AppDelegate.shared when AppDelegate is decomposed.
    let sidebarWorkspaceDragRegistry = SidebarWorkspaceDragRegistry()
    #if DEBUG
    /// Debug-only registry mapping each mounted sidebar's window id to its live
    /// `SidebarDragState`. Owned here (the composition root) and injected into the
    /// sidebar (via `\.sidebarDragStateRegistry`) and the
    /// `debug.sidebar.simulate_drag` reader (via the reader's constructor), so
    /// neither reaches `AppDelegate.shared` for it. Storage moved to
    /// ``AppEnvironment``; forwarder preserved for not-yet-migrated sites.
    var sidebarDragStateRegistry: SidebarDragStateRegistry { environment.sidebarDragStateRegistry }
    var debugFocusedTerminalKeyRepairObserverForTesting: ((NSWindow, NSEvent, NSResponder?) -> Void)?
    #endif
    /// Owns the in-flight "join the next async-created workspace to this group"
    /// watchers for sidebar group `+` actions (CmuxSidebar). Composition-root
    /// owned; replaces the former `ConfiguredGroupActionAsyncWorkspaceObserver`
    /// static `pending` registry, so the watcher state no longer lives on this
    /// singleton.
    let workspaceGroupJoinCoordinator = WorkspaceGroupJoinCoordinator()
    private lazy var updateController = UpdateController(log: environment.updateLog)
    private lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(updateLog: environment.updateLog, settingsRuntime: settingsRuntime)
    private let windowDecorationsController = WindowDecorationsController()
    private let systemWideHotkeyController = SystemWideHotkeyController()
    /// Owns the menu-bar status item lifecycle and application-presentation
    /// preferences. The status menu's app-delegate actions are injected as a
    /// closure seam so the coordinator does not reach back through `self`.
    private lazy var menuBarExtraCoordinator = MenuBarExtraCoordinator(
        callbacks: .init(
            showMainWindow: { [weak self] in
                self?.showMainWindowFromMenuBar()
            },
            showNotifications: { [weak self] in
                self?.showNotificationsPopoverFromMenuBar()
            },
            openNotification: { [weak self] notification in
                _ = self?.openTerminalNotification(notification)
            },
            jumpToLatestUnread: { [weak self] in
                self?.jumpToLatestUnread()
            },
            checkForUpdates: { [weak self] in
                self?.checkForUpdates(nil)
            },
            openPreferences: { [weak self] in
                self?.openPreferencesWindow(debugSource: "menuBarExtra")
            }
        )
    )
    // Internal (not private) so the `ApplicationActivationHost` conformance in
    // `AppDelegate+ApplicationActivationHost.swift` can witness the activation
    // visibility methods that drive it.
    lazy var mainWindowVisibilityController = MainWindowVisibilityController(
        dependencies: .init(
            isActivationSuppressed: {
                TerminalController.shouldSuppressSocketCommandActivation()
                    && !TerminalController.socketCommandAllowsInAppFocusMutations()
            },
            setActiveMainWindow: { [weak self] window in
                self?.setActiveMainWindow(window)
            }
        )
    )
    private static let serviceErrorNoPath = NSString(string: String(localized: "error.clipboardFolderPath", defaultValue: "Could not load any folder path from the clipboard."))
    private static let didInstallWindowKeyEquivalentSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.performKeyEquivalent(with:))
        let swizzledSelector = #selector(NSWindow.cmux_performKeyEquivalent(with:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowFirstResponderSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.makeFirstResponder(_:))
        let swizzledSelector = #selector(NSWindow.cmux_makeFirstResponder(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallWindowSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSWindow.self
        let originalSelector = #selector(NSWindow.sendEvent(_:))
        let swizzledSelector = #selector(NSWindow.cmux_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallApplicationSendEventSwizzle: Void = {
        let targetClass: AnyClass = NSApplication.self
        let originalSelector = #selector(NSApplication.sendEvent(_:))
        let swizzledSelector = #selector(NSApplication.cmux_applicationSendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallApplicationSendActionSwizzle: Void = {
        let targetClass: AnyClass = NSApplication.self
        let originalSelector = #selector(NSApplication.sendAction(_:to:from:))
        let swizzledSelector = #selector(NSApplication.cmux_sendAction(_:to:from:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
    private static let didInstallApplicationAccessibilitySwizzle: Void = {
        let targetClass: AnyClass = NSApplication.self
        let originalSelector = NSSelectorFromString("accessibilityAttributeValue:")
        let swizzledSelector = #selector(NSApplication.cmux_accessibilityAttributeValue(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    /// Diff-viewer launch capability (CmuxWorkspaces); composition-root owned.
    /// It spawns the bundled `cmux diff` CLI and owns the live-subprocess
    /// registry (formerly `diffViewerProcesses` on this delegate), retained
    /// until each child exits. The app injects its shared bounded
    /// `ProcessOutputCollector`, the process environment, the nonzero-exit beep,
    /// and the DEBUG trace sink so the service names none of those app types.
    private let diffViewerLaunchService: any DiffViewerLaunching = {
#if DEBUG
        let debugLog: @Sendable (String) -> Void = { cmuxDebugLog($0) }
#else
        let debugLog: @Sendable (String) -> Void = { _ in }
#endif
        return DiffViewerLaunchService(
            makeOutputDrainer: { stdout, stderr in
                ProcessOutputCollector(stdout: stdout, stderr: stderr)
            },
            environment: { ProcessInfo.processInfo.environment },
            beep: { NSSound.beep() },
            debugLog: debugLog
        )
    }()

    /// `cmux ssh` deep-link launch capability (CmuxWorkspaces); composition-root
    /// owned. It spawns the bundled `cmux ssh` CLI and owns the live-subprocess
    /// registry (formerly the `CmuxSSHURLProcessLauncher.shared` singleton),
    /// retained until each child exits. The app injects its shared bounded
    /// `ProcessOutputCollector`, the process environment, and the DEBUG trace
    /// sink; failure presentation (NSAlert + localized copy) is supplied per call
    /// from the URL-handling shim (`AppDelegate+CmuxSSHURL`).
    let sshURLLaunchService: CmuxSSHURLLaunchService = {
#if DEBUG
        let debugLog: @Sendable (String) -> Void = { cmuxDebugLog($0) }
#else
        let debugLog: @Sendable (String) -> Void = { _ in }
#endif
        return CmuxSSHURLLaunchService(
            makeOutputDrainer: { stdout, stderr in
                ProcessOutputCollector(stdout: stdout, stderr: stderr)
            },
            environment: { ProcessInfo.processInfo.environment },
            debugLog: debugLog
        )
    }()

    /// Default-terminal registration orchestration (CmuxWindowing);
    /// composition-root owned. It coalesces concurrent "Make Default Terminal"
    /// attempts (formerly the `static var inFlightRegistration` on the
    /// `DefaultTerminalUserAction` namespace) and drives the
    /// `DefaultTerminalRegistrar`. The app injects the registrar factory (live
    /// `Bundle.main.bundleURL` + the `.defaultTerminalRegistrationDidChange`
    /// post), the NSAlert failure presenter, and the DEBUG trace sink so the
    /// package names none of those app types.
    lazy var defaultTerminalRegistrationCoordinator: DefaultTerminalRegistrationCoordinator =
        makeDefaultTerminalRegistrationCoordinator()

#if DEBUG
    private var jumpUnreadUITestRecorder: JumpUnreadUITestRecorder?
    private var terminalCmdClickUITestRecorder: TerminalCmdClickUITestRecorder?
    private var gotoSplitUITestRecorder: GotoSplitUITestRecorder?
    private var didSetupTerminalViewportUITest = false
    private var bonsplitTabDragUITestRecorder: BonsplitTabDragUITestRecorder?
    private var terminalViewportUITestRecorder: TerminalViewportUITestRecorder?
#if DEBUG
    /// The display/render/socket/portal diagnostics writer. Created lazily on
    /// first `writeUITestDiagnosticsIfNeeded(stage:)` and reused so the merged
    /// JSON keeps accumulating across stages exactly as the legacy in-place
    /// writer did. Reads live state back through `self` as
    /// ``UITestDiagnosticsProviding``.
    private lazy var displayDiagnosticsUITestRecorder = DisplayDiagnosticsUITestRecorder(provider: self)
    /// The launch-time UI-test scaffold (CmuxTestSupport): owns the
    /// diagnostics-probe install order, the `DispatchQueue.main.asyncAfter`
    /// schedule, and the `CMUX_UI_TEST_*` env gates lifted out of
    /// `applicationDidFinishLaunching`. Built fresh per call site from the
    /// composition-root probes and `self` as ``StartupUITestScaffoldDriving``.
    private var startupUITestScaffold: StartupUITestScaffold {
        StartupUITestScaffold(
            recorder: displayDiagnosticsUITestRecorder,
            stallMonitor: runLoopStallMonitor,
            turnProfiler: mainThreadTurnProfiler,
            driver: self
        )
    }
#endif
    private var multiWindowNotificationUITestScaffold: MultiWindowNotificationUITestScaffold?
    private var displayResolutionUITestRecorder: DisplayResolutionUITestRecorder?
    private var feedSidebarUITestRecorder: FeedSidebarUITestRecorder?
    private var portalStatsUITestRecorder: PortalStatsUITestRecorder?
    private var socketSanityUITestRecorder: SocketSanityUITestRecorder?
    var debugCloseMainWindowConfirmationHandler: ((NSWindow) -> Bool)?
    /// Test seam: when set, ``openDiffViewerForFocusedWorkspace(for:)`` invokes this
    /// instead of spawning the bundled `cmux diff` CLI, so shortcut-dispatch tests can
    /// assert routing without launching a subprocess.
    var debugOpenDiffViewerHandler: (() -> Void)?
    var debugCreateMainWindowSourceIsNativeFullScreenOverride: Bool?
    // Keep debug-only windows alive when tests intentionally inject key mismatches.
    private var debugDetachedContextWindows: [NSWindow] = []

    /// Debug-only env-driven child-exit keyboard probe writer, owned by
    /// ``CmuxTestSupport/ChildExitKeyboardProbeRecorder``. The shortcut-dispatch
    /// path forwards through ``writeChildExitKeyboardProbe(_:increments:)`` and
    /// ``childExitKeyboardProbeHex(_:)`` so the call sites stay unchanged.
    private lazy var childExitKeyboardProbeRecorder = ChildExitKeyboardProbeRecorder()

    private func childExitKeyboardProbeHex(_ value: String?) -> String {
        childExitKeyboardProbeRecorder.hex(value)
    }

    private func writeChildExitKeyboardProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
        childExitKeyboardProbeRecorder.write(updates, increments: increments)
    }
#endif

    /// The single `WindowID`→``WindowContext`` index that replaces the six
    /// parallel `WindowScopedStore<…>` dictionaries this delegate used to hold
    /// (`windowTabManagers`, `windowFocusControllers`, `windowConfigStores`,
    /// `windowSidebarSelectionStates`, `windowSidebarStates`,
    /// `windowFileExplorerStates`). Each main `NSWindow` now has one
    /// ``WindowContext`` holding all six slices; this registry is the single
    /// strong owner + lookup the window-lifecycle seam and the per-window
    /// config/sidebar/file-explorer accessors resolve through. Storage moved to
    /// ``AppEnvironment``; this forwarder keeps the not-yet-migrated
    /// `AppDelegate.windowRegistry` sites resolving to the same instance. The
    /// cross-window resolver family now lives on the registry and AppDelegate
    /// keeps thin compatibility forwarders. A passive index: it does NOT
    /// subscribe to the single-consumer `windowCoordinator.windowClosed` stream;
    /// slice removal is driven by the one `removeWindowModelSlices` teardown
    /// funnel.
    var windowRegistry: WindowRegistry { environment.windowRegistry }

    /// The ``WindowContext`` for `id`, or `nil` if no window is registered under
    /// `id`. The single forwarder the seam methods and config/sidebar accessors
    /// resolve their per-window slices through.
    func windowContext(for id: WindowID) -> WindowContext? {
        windowRegistry.context(for: id)
    }

    private var mainWindowControllers: [MainWindowController] = []

    /// The resolved registered window for `id`, or `nil` if none is registered.
    /// Forwards to ``windowLifecycle``, which funnels through the
    /// ``WindowLifecycleHosting/resolveRegisteredWindow(for:)`` seam impl below.
    func registeredMainWindow(for id: WindowID) -> RegisteredMainWindow? {
        windowLifecycle.registeredWindow(for: id)
    }

    /// Every registered main window as a resolved value, in no guaranteed order
    /// (faithfully matching the old `registeredMainWindows` dictionary
    /// iteration, which was likewise unordered). The single replacement for
    /// `registeredMainWindows`.
    var registeredMainWindows: [RegisteredMainWindow] {
        windowLifecycle.registeredWindows
    }

    /// Every open workspace across all registered main windows (Sleepy-mode pet
    /// census). Main's original read `mainWindowContexts`; that aggregate was
    /// dissolved in the refactor, so this enumerates the per-window tab managers.
    func openWorkspacesForPetCensus() -> [Workspace] {
        registeredMainWindows.flatMap { $0.tabManager.tabs }
    }

    /// In-flight off-main-thread diff-baseline lookup tasks, keyed by task id
    /// (#6497). Retained so a superseding request can cancel a stale lookup.
    var openDiffViewerAgentContextTasks: [String: Task<Void, Never>] = [:]
    /// Pending diff-viewer requests awaiting their baseline-lookup result (#6497),
    /// keyed by task id.
    var openDiffViewerAgentContextPendingRequests: [String: OpenDiffViewerAgentContextRequest] = [:]

    /// Spawns the bundled `cmux diff` CLI for the given workspace/surface,
    /// delegating to the composition-root ``diffViewerLaunchService`` (the
    /// process-lifecycle registry lives there, not on this delegate). Supports
    /// the last-turn agent-diff source, session id, and focus control (#6497).
    @discardableResult
    func launchDiffViewerProcess(
        cliURL: URL,
        socketPath: String,
        cwd: String,
        workspaceId: UUID,
        surfaceId: UUID?,
        useLastTurnSource: Bool,
        sessionId: String?,
        focus: Bool = true
    ) -> Bool {
        diffViewerLaunchService.launch(
            cliURL: cliURL,
            socketPath: socketPath,
            cwd: cwd,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            useLastTurnSource: useLastTurnSource,
            sessionId: sessionId,
            focus: focus
        )
    }

    /// The resolved registered window owning `tabManager`, via the coordinator's
    /// reverse index. Replaces the recurring `registeredMainWindow(forManager:)`.
    func registeredMainWindow(forManager tabManager: TabManager) -> RegisteredMainWindow? {
        windowLifecycle.registeredWindow(forManagerObject: ObjectIdentifier(tabManager))
    }

    /// The resolved registered window for `windowId` (a raw `UUID`), or `nil`.
    func registeredMainWindow(forWindowId windowId: UUID) -> RegisteredMainWindow? {
        windowLifecycle.registeredWindow(for: WindowID(windowId))
    }

    /// The resolved registered window for the NSWindow `window`, by window-object
    /// identity. Forwards to ``windowLifecycle``, which owns window↔id identity and
    /// the late-bound-identifier fallback.
    func registeredMainWindow(forWindow window: NSWindow) -> RegisteredMainWindow? {
        windowLifecycle.registeredWindow(forWindow: window)
    }

    /// Binds `tabManager` to `id` and keeps the coordinator's reverse index
    /// consistent. Forwards to ``windowLifecycle``.
    private func rebindWindowTabManager(_ tabManager: TabManager, for id: WindowID) {
        windowLifecycle.rebindTabManager(tabManager, for: id)
    }

    /// Drops every per-window slice for `id` across all domain stores plus the
    /// coordinator's reverse index. The single removal funnel for both window
    /// teardown paths (the AppKit close path via `unregisterMainWindowContext`,
    /// and the explicit/windowless path via `discardOrphanedMainWindowContext`).
    /// Forwards to ``windowLifecycle``, whose
    /// ``WindowLifecycleHosting/removeWindowModelSlices(for:)`` seam impl below
    /// drops the typed app-side stores.
    @discardableResult
    private func removeWindowSlices(for id: WindowID) -> (tabManager: TabManager, focusController: MainWindowFocusController?)? {
        windowLifecycle.removeWindowSlices(for: id)
    }

    // MARK: - WindowLifecycleHosting registry seam

    /// Builds the ephemeral ``RegisteredMainWindow`` resolved value for `id`, or
    /// `nil` if no window is registered under `id`. The god-type leaf the
    /// coordinator's resolvers funnel through: it reads the window's
    /// ``WindowContext`` (`tabManager` + `focusController`) from
    /// ``windowRegistry`` and resolves the live `NSWindow` through
    /// ``windowCoordinator`` then the identifier fallback, reproducing the old
    /// class's `window ?? windowForMainWindowId(windowId)` read. (A context only
    /// exists once both tab manager and focus controller are seeded together, so
    /// `context != nil` is exactly the old "both slices present" guard.)
    func resolveRegisteredWindow(for id: WindowID) -> RegisteredMainWindow? {
        guard let context = windowRegistry.context(for: id) else { return nil }
        let window = windowCoordinator.window(for: id) ?? windowForMainWindowId(id.rawValue)
        return RegisteredMainWindow(
            windowId: id.rawValue,
            tabManager: context.tabManager,
            keyboardFocusCoordinator: context.focusController,
            window: window
        )
    }

    /// The ``WindowID``s currently registered, in no guaranteed order (the
    /// ``windowRegistry`` id set). Backs the coordinator's `registeredWindows`.
    var registeredWindowIds: [WindowID] {
        windowRegistry.ids
    }

    /// The live `NSWindow` bound to `registeredWindow`, for the coordinator's
    /// late-bound-identifier `registeredWindow(forWindow:)` fallback.
    func window(of registeredWindow: RegisteredMainWindow) -> NSWindow? {
        registeredWindow.window
    }

    /// Rebinds `tabManager` on the window's ``WindowContext``, returning the
    /// `ObjectIdentifier` of the distinct manager previously bound to `id` (for
    /// the coordinator's stale reverse-index drop), or `nil`. Faithfully preserves
    /// the old `previous !== tabManager` guard. Always called right after a
    /// seed/rebind, so the context exists; the `else` never triggers.
    func rebindTabManagerSlice(_ tabManager: TabManager, for id: WindowID) -> ObjectIdentifier? {
        guard let context = windowRegistry.context(for: id) else { return nil }
        let previous = context.tabManager
        context.tabManager = tabManager
        if previous !== tabManager {
            return ObjectIdentifier(previous)
        }
        return nil
    }

    /// Drops the window's ``WindowContext`` for `id` (and with it all six slices),
    /// returning the removed tab manager and focus controller, or `nil` if nothing
    /// was registered under `id`. Faithfully reproduces the old per-store
    /// `remove(_:)` calls; the reverse-index drop now lives on the coordinator.
    func removeWindowModelSlices(for id: WindowID) -> (tabManager: TabManager, focusController: MainWindowFocusController?)? {
        guard let context = windowRegistry.removeContext(for: id) else { return nil }
        // Tear down this window's independent Dock (#7144) so its live
        // terminals/browsers and their portals die with the window instead of
        // outliving it as headless PTYs.
        context.teardownWindowDock()
        return (context.tabManager, context.focusController)
    }

    /// The window id carried by `registeredWindow`. Lets the coordinator key
    /// slice/identity removal and palette/lifecycle calls by the resolved
    /// context's id (the ``WindowLifecycleHosting`` leaf accessor).
    func windowId(of registeredWindow: RegisteredMainWindow) -> UUID {
        registeredWindow.windowId
    }

    /// Records a recoverable route for `context` before its slices are dropped.
    /// Unpacks the app value type's fields for the existing route-ledger writer.
    func rememberRecoverableMainWindowRoute(for context: RegisteredMainWindow) {
        rememberRecoverableMainWindowRoute(
            windowId: context.windowId,
            tabManager: context.tabManager,
            window: context.window
        )
    }

    /// Drops `context`'s tab manager from the mobile workspace-list observer
    /// index when no remaining window references it.
    func removeMobileWorkspaceListObserver(forClosing context: RegisteredMainWindow) {
        removeMobileWorkspaceListObserverIfUnused(for: context.tabManager)
    }

    // MARK: - WindowLifecycleHosting registration ingest seam

    /// Whether a window is registered under `id`. Backs the coordinator's
    /// rebind-vs-seed branch decision. A context exists iff the tab manager was
    /// seeded, so this is exactly the old `windowTabManagers` membership check.
    func isMainWindowRegistered(_ id: WindowID) -> Bool {
        windowRegistry.context(for: id) != nil
    }

    /// Re-points the existing live window registered under `existingId` when a
    /// duplicate window arrives for the same id, then leaves the duplicate
    /// `window`'s `orderOut`/`close` to the coordinator. Faithfully reproduces the
    /// old `registerMainWindow` duplicate-ignored branch (debug log + existing
    /// manager / focus-controller re-point).
    func handleDuplicateMainWindowRegistration(
        windowId: UUID,
        existingId: WindowID,
        existingWindow: NSWindow,
        duplicate: NSWindow
    ) {
#if DEBUG
        cmuxDebugLog(
            "mainWindow.register.duplicateIgnored windowId=\(String(windowId.uuidString.prefix(8))) " +
                "existing={\(debugWindowToken(existingWindow))} duplicate={\(debugWindowToken(duplicate))}"
        )
#endif
        if let context = windowRegistry.context(for: existingId) {
            let existingManager = context.tabManager
            existingManager.window = existingWindow
            existingManager.windowId = windowId
            context.focusController.update(
                window: existingWindow,
                tabManager: existingManager,
                fileExplorerState: context.fileExplorerState
            )
        }
    }

    /// Re-points the per-window slices for an already-registered `resolvedId` at
    /// `window`/`tabManager`. The coordinator owns the reverse-index rebind and the
    /// `windowCoordinator.register` identity write around this call, so this funnel
    /// writes only the disjoint per-window stores + focus-controller update (the
    /// shared body of the old `registerMainWindow` rebind branches).
    func rebindRegisteredWindowSlices(
        window: NSWindow,
        resolvedId: WindowID,
        tabManager: TabManager,
        slices: MainWindowRegistrationSlices
    ) {
        tabManager.window = window
        tabManager.windowId = resolvedId.rawValue
        // The coordinator only takes the rebind branch when the window is already
        // registered, so the context exists. Note the tab-manager rebind on the
        // context itself happens in `rebindTabManagerSlice`, called right after;
        // the focus-controller update below uses the new `tabManager` param, not
        // `context.tabManager` (which is still the old manager here), exactly as
        // before.
        guard let context = windowRegistry.context(for: resolvedId) else { return }
        let resolvedFileExplorerState = slices.fileExplorerState ?? context.fileExplorerState
        if let fileExplorerState = slices.fileExplorerState {
            context.fileExplorerState = fileExplorerState
        }
        context.focusController.update(
            window: window,
            tabManager: tabManager,
            fileExplorerState: resolvedFileExplorerState
        )
        if let cmuxConfigStore = slices.cmuxConfigStore {
            context.configStore = cmuxConfigStore
        }
    }

    /// Seeds every per-window slice for a brand-new window `newId` (the old
    /// `registerMainWindow` else-branch): a freshly constructed
    /// ``MainWindowFocusController`` plus the sidebar / sidebar selection /
    /// optional file-explorer / optional config-store stores. The coordinator
    /// owns the reverse-index rebind and identity write around this call.
    func seedNewMainWindowSlices(
        window: NSWindow,
        windowId: UUID,
        newId: WindowID,
        tabManager: TabManager,
        slices: MainWindowRegistrationSlices
    ) {
        tabManager.window = window
        tabManager.windowId = windowId
        let focusController = MainWindowFocusController(
            windowId: windowId,
            window: window,
            tabManager: tabManager,
            fileExplorerState: slices.fileExplorerState,
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )
        windowRegistry.setContext(
            WindowContext(
                windowId: newId,
                tabManager: tabManager,
                focusController: focusController,
                sidebarState: slices.sidebarState,
                sidebarSelectionState: slices.sidebarSelectionState,
                fileExplorerState: slices.fileExplorerState,
                configStore: slices.cmuxConfigStore
            ),
            for: newId
        )
    }

    /// Registers `windowId` with the command-palette presentation coordinator.
    func commandPaletteRegisterWindow(_ windowId: UUID) {
        commandPalettePresentation.registerWindow(windowId)
    }

    /// Ensures the per-tab-manager socket listener when socket control is enabled.
    func ensureSocketListener(for tabManager: TabManager, source: String) {
        ensureSocketListenerIfEnabled(tabManager: tabManager, source: source)
    }

    /// Applies the one-shot startup session restore if it has not run yet,
    /// returning whether a restore was applied this call.
    func attemptStartupSessionRestore(primaryWindow: NSWindow) -> Bool {
        attemptStartupSessionRestoreIfNeeded(primaryWindow: primaryWindow)
    }

    /// Whether a session snapshot should be written immediately after this
    /// registration, applying the persistence policy against the live
    /// terminating / restoring flags.
    func shouldSaveSnapshotAfterMainWindowRegistration(didApplyStartupSessionRestore: Bool) -> Bool {
        Self.sessionPersistenceDecisionPolicy.shouldSaveSessionSnapshotAfterMainWindowRegistration(
            isTerminatingApp: isTerminatingApp,
            didApplyStartupSessionRestore: didApplyStartupSessionRestore,
            isApplyingSessionRestore: isApplyingSessionRestore
        )
    }

    /// Writes the post-registration session snapshot (no scrollback).
    func saveSessionSnapshotAfterMainWindowRegistration() {
        saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
    }

#if DEBUG
    /// The currently active tab manager, captured before a registration mutates
    /// the registry so the post-registration debug log can report the prior
    /// active manager.
    var activeTabManagerForRegistrationDebug: TabManager? {
        tabManager
    }

    /// Emits the `mainWindow.register` debug log after the registry mutates.
    func logMainWindowRegistered(
        windowId: UUID,
        window: NSWindow,
        tabManager: TabManager,
        priorActiveTabManager: TabManager?
    ) {
        cmuxDebugLog(
            "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(debugManagerToken(priorActiveTabManager)) \(debugShortcutRouteSnapshot())"
        )
    }

    /// Seeds every per-window slice for the DEBUG-only window-less testing
    /// registration of `testId` (the old `registerMainWindowContextForTesting`
    /// body, minus the reverse-index rebind + observer/notify the coordinator now
    /// sequences).
    func seedTestingMainWindowSlices(
        windowId: UUID,
        testId: WindowID,
        tabManager: TabManager,
        slices: MainWindowRegistrationSlices
    ) {
        tabManager.windowId = windowId
        let focusController = MainWindowFocusController(
            windowId: windowId,
            window: nil,
            tabManager: tabManager,
            fileExplorerState: slices.fileExplorerState,
            surfaceFocusResolver: AppTerminalSurfaceFocusResolver()
        )
        windowRegistry.setContext(
            WindowContext(
                windowId: testId,
                tabManager: tabManager,
                focusController: focusController,
                sidebarState: slices.sidebarState,
                sidebarSelectionState: slices.sidebarSelectionState,
                fileExplorerState: slices.fileExplorerState,
                configStore: slices.cmuxConfigStore
            ),
            for: testId
        )
    }
#endif

    /// Window-lifecycle layer, lifted into `CmuxWindowing`. Owns window identity
    /// and lifecycle: the ``WindowManaging`` coordinator (the live `WindowID`
    /// set, the `NSWindow` handle per window, and the single window-closed
    /// broadcast), the `TabManager`→`WindowID` reverse index, the suppressed
    /// closed-window-history ids, and the new-window cascade anchor. This is the
    /// de-aggregation keystone — the close-observer responsibility that used to
    /// live on `MainWindowContext.closeObserver` is drained here (owner ruling
    /// 2026-06-18: per-window state is domain-owned and `WindowID`-keyed, never
    /// bundled into one per-window aggregate). Constructed once at the
    /// composition root with `self` as the weak teardown host;
    /// `windowCoordinator.windowClosed` is consumed by
    /// ``WindowLifecycleCoordinator/observeWindowCoordinatorClosures()`` to drive
    /// the app-side `unregisterMainWindow` teardown.
    lazy var windowLifecycle = WindowLifecycleCoordinator(host: self)

    /// Forwards to ``windowLifecycle``'s owned window-identity coordinator, which
    /// owns window↔id identity and the single window-closed stream.
    var windowCoordinator: any WindowManaging { windowLifecycle.windowCoordinator }

    /// The per-window ``SidebarSelectionState`` for `context`, resolved through
    /// the window's ``WindowContext`` in ``windowRegistry``. `registerMainWindow`
    /// always seeds the slice before the context is reachable, so a live context
    /// always has one; the empty-state fallback only guards an already-torn-down
    /// context (whose ``WindowContext`` has been dropped) and preserves the
    /// never-`nil` invariant the lifted `let` field had.
    func sidebarSelectionState(for context: RegisteredMainWindow) -> SidebarSelectionState {
        if let wctx = windowRegistry.context(for: WindowID(context.windowId)) {
            return wctx.sidebarSelectionState
        }
        return SidebarSelectionState()
    }

    /// The per-window ``SidebarState`` for `context`, resolved through the
    /// window's ``WindowContext`` in ``windowRegistry``. `registerMainWindow`
    /// always seeds the slice before the context is reachable, so a live context
    /// always has one; the empty-state fallback only guards an already-torn-down
    /// context and preserves the never-`nil` invariant the lifted `let` field had.
    func sidebarState(for context: RegisteredMainWindow) -> SidebarState {
        if let wctx = windowRegistry.context(for: WindowID(context.windowId)) {
            return wctx.sidebarState
        }
        return SidebarState()
    }

    /// The per-window ``FileExplorerState`` for `context`, resolved through the
    /// window's ``WindowContext`` in ``windowRegistry``, or `nil` when the window
    /// has none yet. Unlike ``sidebarState(for:)`` this has NO empty-state
    /// fallback: the lifted field was an optional `var FileExplorerState?` that
    /// was nil until lazily bound, so a missing slice must read back as `nil` to
    /// preserve that exact semantics (callers already coalesce against the
    /// active-window mirror or bail on `nil`).
    func fileExplorerState(for context: RegisteredMainWindow) -> FileExplorerState? {
        windowRegistry.context(for: WindowID(context.windowId))?.fileExplorerState
    }

    /// Tracks the cascade point for new windows, matching Ghostty's upstream algorithm.
    /// Reset to `.zero` so the first window seeds the point from its own position.
    /// Stored on ``windowLifecycle``; forwarded so the existing read/write sites
    /// resolve unchanged.
    private var lastCascadePoint: NSPoint {
        get { windowLifecycle.lastCascadePoint }
        set { windowLifecycle.lastCascadePoint = newValue }
    }
    private(set) var startupSessionSnapshot: AppSessionSnapshot?
    private var didPrepareStartupSessionSnapshot = false
    var didAttemptStartupSessionRestore = false
    static let screenChangeReconcileNotification = Notification.Name("com.cmuxterm.app.screenChangeReconcile")
    static let displayReconfigurationNotification = Notification.Name("com.cmuxterm.app.displayReconfiguration")
    static let screenChangeReconcileRetryLimit = 3
    var isApplyingSessionRestore = false
    /// Durable navigation links that arrived before startup restore registered
    /// their target workspaces.
    var pendingStartupNavigationURLRequests: [CmuxNavigationURLRequest] = []
    var windowConfigFrames: [UUID: SessionConfigFrameRing] = [:]
    var lastAppliedConfigurationSignature: String?, lastVisibleFrameFitTopologySignature: [MainWindowVisibleFrameTopologySignatureEntry]?
    var didObserveUnknownVisibleFrameFitTopology = false, didObserveUnknownDisplayConfiguration = false
    var visibleFrameFitTopologyRetryBudget = 0, screenChangeReconcileRetryBudget = 0
    var isScreenChangeCaptureSuppressed = false
    var screenChangeCaptureSuppressionSignature: String?
    var screenChangeCaptureSuppressionSignatureGeneration: Int?
    var displayReconfigurationGeneration = 0
    var didRegisterDisplayReconfigurationCallback = false
    private var processDetectedSessionSaveGeneration: UInt64 = 0
    private let sessionPersistenceQueue = DispatchQueue(
        label: "com.cmuxterm.app.sessionPersistence",
        qos: .utility
    )
    /// Session-snapshot autosave cadence (CmuxWorkspaces); composition-root
    /// owned. Owns the repeating-timer task, the typing-quiet deferral, and the
    /// in-flight latch the legacy `DispatchSourceTimer` + serial-queue retry
    /// used; `AppDelegate` conforms to ``SessionAutosaveScheduling`` and the
    /// scheduler calls back through ``performScheduledAutosave(source:)``. The
    /// `XCTest` suspension check matches the legacy guard in the old
    /// `startSessionAutosaveTimerIfNeeded()`.
    private lazy var sessionAutosaveScheduler: SessionAutosaveScheduler = {
        let scheduler = SessionAutosaveScheduler(
            interval: .seconds(Int64(SessionPersistencePolicy.autosaveInterval)),
            isAutosaveSuspended: { [weak self] in
                guard let self else { return true }
                return self.isRunningUnderXCTest(ProcessInfo.processInfo.environment)
            }
        )
        scheduler.attach(host: self)
        return scheduler
    }()

    /// Pane/surface movement between panes, workspaces, and windows
    /// (CmuxWorkspaces); composition-root owned. Owns the move decision
    /// (destination-pane resolution, same-workspace-split / same-workspace-move /
    /// cross-workspace path selection, the bonsplit-tab → panel-id indirection,
    /// and the existing-workspace move-target projection); every live
    /// `Workspace`/`TabManager`/bonsplit mutation, the cross-workspace
    /// detach-scoped tail, and the cross-window focus reassert invert back through
    /// ``PaneSurfaceMoveHosting`` (witnesses in
    /// `AppDelegate+PaneSurfaceMoveHosting.swift`). `AppDelegate` keeps the thin
    /// public entrypoints (`moveSurface`, `moveBonsplitTab`, `workspaceMoveTargets`)
    /// that build the typed request and forward.
    lazy var paneSurfaceMove: PaneLayoutControlling = {
        let coordinator = PaneSurfaceMoveCoordinator()
        coordinator.attach(host: self)
        return coordinator
    }()

    /// Cross-window new-workspace / new-browser / cloud-VM action routing
    /// (CmuxWorkspaces); composition-root owned. Owns the routing decision logic
    /// (window selection, gate ordering, in-group placement resolution, the
    /// close-initial-workspace condition); every app effect inverts back through
    /// ``WorkspaceCreationActionHosting`` (witnesses in
    /// `AppDelegate+WorkspaceCreationActionHosting.swift`). `AppDelegate` keeps
    /// the thin public action entrypoints (which build the opaque
    /// ``WorkspaceCreationActionSelector``) and the NSMenu presentation app-side.
    lazy var workspaceCreationActions = WorkspaceCreationActionCoordinator(host: self)
    /// Recently-closed-history reopen/clear routing (CmuxWorkspaces);
    /// composition-root owned. Owns the cross-window reopen interleave and clear
    /// sequence; inverts every store / registry / window-lifecycle / focus effect
    /// back through this `AppDelegate`'s ``ClosedItemReopenHosting`` conformance.
    lazy var closedItemReopen = ClosedItemReopenCoordinator(host: self)
    /// Session snapshot persistence (CmuxSession); composition-root owned.
    /// `nonisolated` because the autosave write block runs on `sessionPersistenceQueue`.
    nonisolated let sessionSnapshotStore: any SessionSnapshotStoring<AppSessionSnapshot> = SessionSnapshotRepository(
        schemaVersion: AppSessionSnapshot.currentSchemaVersion,
        bundleIdentifier: Bundle.main.bundleIdentifier
    )
    /// Session-snapshot + primary-window-geometry write coordinator
    /// (CmuxWorkspaces); composition-root owned. Owns the serial persistence
    /// queue and sequences the geometry write and the snapshot write into one
    /// block, exactly as the legacy `persistSessionSnapshot` write block did.
    /// Reuses the held ``sessionSnapshotStore`` so the snapshot file store has a
    /// single owner; the persistor value is `Sendable` and the queued write
    /// block it dispatches captures only `Sendable` values, so it is only
    /// accessed from the main-actor `persistSessionSnapshot`.
    private lazy var sessionSnapshotPersistor = SessionSnapshotPersistor(
        snapshotStore: sessionSnapshotStore,
        geometryStore: Self.windowGeometryStore,
        geometryDefaults: .standard,
        queue: sessionPersistenceQueue,
        markCrashOnlyPrimarySnapshotRemoval: {
            AppDelegate.markCrashOnlyPrimarySnapshotRemoval()
        },
        clearCrashOnlyPrimarySnapshotRemovalMarker: {
            AppDelegate.clearCrashOnlyPrimarySnapshotRemovalMarker()
        }
    )
    /// External-open URL classifier (CmuxWorkspaces); composition-root owned.
    /// The deep-link/services shims forward the pure URL-shaping rules here,
    /// injecting `Bundle.main.bundleURL` and the app-target
    /// `FinderServicePathResolver` as the single source of directory ordering.
    let externalOpenURLClassifier: any ExternalOpenURLClassifying = ExternalOpenURLClassifier(
        bundleURL: Bundle.main.bundleURL,
        orderedUniqueDirectories: { pathURLs, excludedRootURLs in
            FinderServicePathResolver().orderedUniqueDirectories(
                from: pathURLs,
                excludingDescendantsOf: excludedRootURLs
            )
        }
    )
    /// Finder NSServices pasteboard path resolver (CmuxWindowing);
    /// composition-root owned. The `@objc openWindow`/`openTab` selector
    /// targets stay in the app target (AppKit dispatches the service to them)
    /// and forward their pasteboard here; the file-URL reading is backed by the
    /// app-target ``PasteboardFileURLReader`` through
    /// ``PasteboardServiceFileURLReader``.
    private let serviceOpenResolver: any ServiceOpenResolving = ServiceOpenPasteboardResolver(
        fileURLReader: PasteboardServiceFileURLReader()
    )
    /// External open-intent decision/loop coordinator (CmuxWorkspaces);
    /// composition-root owned. Maps each resolved external-open directory to a
    /// new-window vs preferred-main-window workspace open. The app conforms to
    /// ``ExternalOpenIntentHosting`` and injects itself as the host, so the
    /// three app-only effects (window creation, preferred-window workspace add,
    /// startup open-intent latch) and the localized error string stay app-side
    /// while the decision/loop lives in the package.
    lazy var externalOpenIntentCoordinator = ExternalOpenIntentCoordinator(host: self)
    /// External-URL open router (CmuxWindowing); composition-root owned. The
    /// `application(_:open:)` entry forwards the opened URLs here; the router
    /// orchestrates the cmux-scheme routes, auth callbacks, and the partitioned
    /// ``DeepLinkOpenPlan`` (built by the injected ``DeepLinkOpenPlanner``)
    /// against the live window/workspace routing this delegate vends as its
    /// ``ExternalURLOpenRouterHost``.
    private lazy var externalURLOpenRouter = ExternalURLOpenRouter(
        router: DeepLinkOpenPlanner(),
        host: self
    )
    /// Accessibility window-hierarchy cache (CmuxWindowing). The `NSApplication`
    /// AX swizzle forwards to it behind ``AccessibilityWindowCaching``. Storage
    /// moved to ``AppEnvironment`` (still `nonisolated(unsafe)` there); this
    /// `nonisolated` forwarder keeps the swizzle's `nonisolated` `@objc` read
    /// path working, guarded by `Thread.isMainThread` at the call site exactly
    /// as before.
    nonisolated var accessibilityWindowCache: any AccessibilityWindowCaching { environment.accessibilityWindowCache }
    /// First-responder bypass guard (CmuxBrowserPanel); composition-root owned.
    /// The `NSWindow.makeFirstResponder` swizzle reads `isActive` and
    /// `BrowserPanel` wraps responder-churning devtools work in `withBypass(_:)`.
    nonisolated let browserFirstResponderBypass = BrowserFirstResponderBypass()
    private nonisolated static let launchServicesRegistrationQueue = DispatchQueue(
        label: "com.cmuxterm.app.launchServicesRegistration",
        qos: .utility
    )
    private nonisolated static func enqueueLaunchServicesRegistrationWork(_ work: @escaping @Sendable () -> Void) {
        launchServicesRegistrationQueue.async(execute: work)
    }
    private var lastSessionAutosaveFingerprint: Int?
    private var lastSessionAutosavePersistedAt: Date = .distantPast
    var didHandleExplicitOpenIntentAtStartup = false
    private var didScheduleInitialMainWindowBootstrap = false
    var shouldDeferInitialMainWindowBootstrapForExternalConfirmation = false
    private var didBootstrapInitialMainWindow = false
    // Internal (not private) so the ``SessionAutosaveScheduling`` conformance
    // can read it as the per-tick termination guard.
    var isTerminatingApp = false
    private var closedWindowHistorySuppressedWindowIds: Set<UUID> {
        get { windowLifecycle.closedWindowHistorySuppressedWindowIds }
        set { windowLifecycle.closedWindowHistorySuppressedWindowIds = newValue }
    }
#if DEBUG
    var closeMainWindowContainingTabIdObserverForTesting: ((UUID, Bool) -> Void)?
#endif
    /// Owns the quit / terminate reply state machine (the one-shot reply latch,
    /// the kill-before-quit deferral, the watchdog Clock task, and the
    /// quit-warning-confirmed flag), draining it out of this delegate. The live
    /// reply, remote-tmux, teardown, breadcrumb, and confirmation-alert work
    /// stays here behind the ``ApplicationTerminationHost`` seam this delegate
    /// conforms to.
    private lazy var terminateReply = ApplicationTerminateReplyCoordinator(host: self)
    private var activeQuitConfirmationAlertPresenter: QuitConfirmationAlertPresenter?
    private var activeQuitConfirmationOwnsTerminateRequest = false
    /// Owns the application activation / resign lifecycle sequencing (pre/post
    /// activation window visibility, the did-become-active breadcrumb + analytics,
    /// the notification activation/unread reconcile, and the resign-time chord
    /// clear + session-snapshot decision), draining it out of this delegate. The
    /// live visibility, telemetry, notification, chord, and session-snapshot work
    /// stays here behind the ``ApplicationActivationHost`` seam this delegate
    /// conforms to.
    private lazy var activationCoordinator = ApplicationActivationCoordinator(host: self)
    /// Owns the stateless application/dock menu-building decisions, emitting
    /// Sendable ``DockMenuSpec`` values. The live `NSMenu`/`NSMenuItem`
    /// materialization, the `@objc openNewMainWindow` selector wiring, and the
    /// `String(localized:)` title resolution stay here behind the
    /// ``AppMenuHosting`` seam this delegate conforms to.
    private lazy var appMenuCoordinator = AppMenuCoordinator(host: self)
    /// Owns the three `NSWorkspace` session-lifecycle observers
    /// (willPowerOff / sessionDidResignActive / didWake) and surfaces them as a
    /// typed ``SessionLifecycleEvent`` `AsyncStream` (CmuxWorkspaces);
    /// composition-root owned. `AppDelegate` consumes the stream on the main
    /// actor in ``lifecycleSnapshotConsumeTask`` and forwards each event to the
    /// same app-coupled save / socket-restart bodies the legacy
    /// `NotificationCenter` closures called.
    private let sessionLifecycleObserver = SessionLifecycleObserver()
    /// The main-actor task draining ``sessionLifecycleObserver``'s event stream.
    /// Replaces the legacy `didInstallLifecycleSnapshotObservers` install-once
    /// latch; created once in `installLifecycleSnapshotObserversIfNeeded()`.
    private var lifecycleSnapshotConsumeTask: Task<Void, Never>?
    private var screenParametersObserver: NSObjectProtocol?
    private var displayReconfigurationObserver: NSObjectProtocol?
    private var screenChangeReconcileObserver: NSObjectProtocol?
    /// Owns the control-socket listener lifecycle policy (configuration
    /// resolution, start/ensure/restart sequencing, the sudden-termination
    /// latch); the live listener and tab-manager resolution stay here behind the
    /// `SocketListenerLifecycleHost` seam this delegate conforms to.
    private lazy var socketListenerLifecycle = SocketListenerLifecycleCoordinator(host: self)
    /// Owns the per-window command-palette request/visibility/escape-suppression/
    /// selection/snapshot state machine (keyed by `WindowID`). This delegate
    /// resolves `NSWindow` values to identifiers and reads the live NSResponder/
    /// overlay hierarchy, then forwards the window-agnostic work into the
    /// coordinator. The coordinator owns the backing `CommandPaletteWindowStore`.
    lazy var commandPalettePresentation: CommandPalettePresentationCoordinator = {
        CommandPalettePresentationCoordinator(
            effects: CommandPalettePresentationEffects(
                log: { message in
#if DEBUG
                    cmuxDebugLog(message)
#endif
                }
            )
        )
    }()

    var updateViewModel: UpdateStateModel {
        updateController.model
    }

#if DEBUG
    private func pointerString(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private func summarizeContextForWorkspaceRouting(_ context: RegisteredMainWindow?) -> String {
        guard let context else { return "nil" }
        let window = context.window ?? windowForMainWindowId(context.windowId)
        let windowNumber = window?.windowNumber ?? -1
        let key = window?.isKeyWindow == true ? 1 : 0
        let main = window?.isMainWindow == true ? 1 : 0
        let visible = window?.isVisible == true ? 1 : 0
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        return "wid=\(context.windowId.uuidString.prefix(8)) win=\(windowNumber) key=\(key) main=\(main) vis=\(visible) tabs=\(context.tabManager.tabs.count) sel=\(selected) tm=\(pointerString(context.tabManager))"
    }

    private func summarizeAllContextsForWorkspaceRouting() -> String {
        guard !registeredMainWindows.isEmpty else { return "<none>" }
        return registeredMainWindows
            .map { summarizeContextForWorkspaceRouting($0) }
            .joined(separator: " | ")
    }

    // Relaxed from `private` to `internal` so the `WorkspaceCreationActionHosting`
    // witnesses (AppDelegate+WorkspaceCreationActionHosting.swift) can emit the
    // fallback-new-window breadcrumb; DEBUG-only, like the original.
    func logWorkspaceCreationRouting(
        phase: String,
        source: String,
        reason: String,
        event: NSEvent?,
        chosenContext: RegisteredMainWindow?,
        workspaceId: UUID? = nil,
        workingDirectory: String? = nil
    ) {
        let eventWindowNumber = event?.window?.windowNumber ?? -1
        let eventNumber = event?.windowNumber ?? -1
        let eventChars = safeShortcutCharactersIgnoringModifiers(for: event)
        let eventKeyCode = event.map { String($0.keyCode) } ?? "nil"
        let keyWindowNumber = NSApp.keyWindow?.windowNumber ?? -1
        let mainWindowNumber = NSApp.mainWindow?.windowNumber ?? -1
        let ws = workspaceId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let wd = workingDirectory.map { String($0.prefix(120)) } ?? "-"
        focusLog.append(
            "cmdn.route phase=\(phase) src=\(source) reason=\(reason) eventWin=\(eventWindowNumber) eventNum=\(eventNumber) keyCode=\(eventKeyCode) chars=\(eventChars) keyWin=\(keyWindowNumber) mainWin=\(mainWindowNumber) activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(chosenContext))} ws=\(ws) wd=\(wd) contexts=[\(summarizeAllContextsForWorkspaceRouting())]"
        )
    }

    private func safeShortcutCharactersIgnoringModifiers(for event: NSEvent?) -> String {
        guard let event, event.type == .keyDown || event.type == .keyUp else { return "" }
        return event.charactersIgnoringModifiers ?? ""
    }
#endif

    override init() {
        // Constructed here (a main-actor context) rather than as the stored
        // default: the property is `nonisolated(unsafe)` so the accessibility
        // swizzle can read through it, and a nonisolated default-value context
        // may not call AppEnvironment's main-actor init.
        self.environment = AppEnvironment()
        super.init()
        windowRegistry.configureHostSeams(
            WindowRegistryHostSeams(
                registeredMainWindows: { [weak self] in
                    self?.registeredMainWindows ?? []
                },
                registeredMainWindowForManager: { [weak self] tabManager in
                    self?.registeredMainWindow(forManager: tabManager)
                },
                registeredMainWindowForWindowId: { [weak self] windowId in
                    self?.registeredMainWindow(forWindowId: windowId)
                },
                contextForMainTerminalWindow: { [weak self] window, reindex in
                    self?.contextForMainTerminalWindow(window, reindex: reindex)
                },
                mainWindowIdFromWindow: { [weak self] window in
                    self?.mainWindowId(from: window)
                },
                windowForMainWindowId: { [weak self] windowId in
                    self?.windowForMainWindowId(windowId)
                }
            )
        )
        // Built as a mutable local so the DEBUG-only seams can be assigned in a
        // statement-level `#if DEBUG` block below: `#if` cannot split an
        // argument list, so the conditional closures stay out of the init call.
        var routerSeams = MainWindowRouterHostSeams(
                shortcutRoutingKeyWindow: { [weak self] in
                    self?.shortcutRoutingKeyWindow
                },
                contextForMainWindow: { [weak self] window in
                    self?.contextForMainWindow(window)
                },
                registeredMainWindows: { [weak self] in
                    self?.registeredMainWindows ?? []
                },
                registeredMainWindowForManager: { [weak self] tabManager in
                    self?.registeredMainWindow(forManager: tabManager)
                },
                resolvedWindow: { [weak self] context in
                    self?.resolvedWindow(for: context)
                },
                windowForMainWindowId: { [weak self] windowId in
                    self?.windowForMainWindowId(windowId)
                },
                setActiveMainWindow: { [weak self] window in
                    self?.setActiveMainWindow(window)
                },
                discardOrphanedMainWindowContext: { [weak self] context in
                    self?.discardOrphanedMainWindowContext(context)
                },
                focusMainWindow: { [weak self] windowId in
                    self?.windowLifecycle.focusMainWindow(windowId: windowId) ?? false
                },
                closeMainWindow: { [weak self] windowId, recordHistory in
                    self?.windowLifecycle.closeMainWindow(windowId: windowId, recordHistory: recordHistory) ?? false
                },
                discardMainWindowWithoutClosedHistory: { [weak self] windowId in
                    self?.discardMainWindowWithoutClosedHistory(windowId: windowId)
                },
                closeWindowContainingTabId: { [weak self] tabId, recordHistory in
                    self?.closeMainWindowContainingTabId(tabId, recordHistory: recordHistory)
                },
                createMainWindow: { [weak self] in
                    self?.createMainWindow()
                },
                focusForInWindowCommand: { [weak self] window, reason in
                    self?.mainWindowVisibilityController.focusForInWindowCommand(window, reason: reason)
                },
                setActiveTerminalControlTabManager: { [weak self] tabManager in
                    self?.terminalControl.setActiveTabManager(tabManager)
                },
                reassertCrossWindowSurfaceMoveFocus: { [weak self] destinationWindowId, sourceWindowId, destinationWorkspaceId, destinationPanelId, destinationManager in
                    self?.reassertCrossWindowSurfaceMoveFocusIfNeeded(
                        destinationWindowId: destinationWindowId,
                        sourceWindowId: sourceWindowId,
                        destinationWorkspaceId: destinationWorkspaceId,
                        destinationPanelId: destinationPanelId,
                        destinationManager: destinationManager
                    )
                },
                paneSurfaceMoveTargets: { [weak self] summaries, excludingWorkspaceId in
                    self?.paneSurfaceMove.moveTargets(for: summaries, excludingWorkspaceId: excludingWorkspaceId) ?? []
                },
                bringToFront: { [weak self] window in
                    self?.bringToFront(window)
                },
                showMainWindowFromMenuBar: { [weak self] in
                    self?.showMainWindowFromMenuBar()
                },
                activateMainWindowFromSocket: { [weak self] in
                    self?.activateMainWindowFromSocket() ?? false
                },
                focusWindowForAppActivation: { [weak self] window, reason in
                    self?.focusWindowForAppActivation(window, reason: reason) ?? false
                },
                preferredWindowForSettingsPresentation: { [weak self] in
                    self?.preferredMainWindowForSettingsPresentation()
                },
                performNewWorkspaceAction: { [weak self] preferredTabManager, event, debugSource in
                    self?.performNewWorkspaceAction(
                        tabManager: preferredTabManager,
                        event: event,
                        debugSource: debugSource
                    ) ?? false
                },
                performNewBrowserWorkspaceAction: { [weak self] preferredTabManager, event, debugSource in
                    self?.performNewBrowserWorkspaceAction(
                        tabManager: preferredTabManager,
                        event: event,
                        debugSource: debugSource
                    ) ?? false
                },
                performCloudVMAction: { [weak self] preferredTabManager, preferredWindow, debugSource, onCompletion in
                    self?.performCloudVMAction(
                        tabManager: preferredTabManager,
                        preferredWindow: preferredWindow,
                        debugSource: debugSource,
                        onCompletion: onCompletion
                    ) ?? false
                },
                showNewWorkspaceContextMenu: { [weak self] anchorView, event, debugSource in
                    self?.showNewWorkspaceContextMenu(
                        anchorView: anchorView,
                        event: event,
                        debugSource: debugSource
                    ) ?? false
                },
                showOpenFolderInInlineVSCodePanel: { [weak self] preferredTabManager in
                    self?.showOpenFolderInInlineVSCodePanel(tabManager: preferredTabManager)
                },
                showFocusHistoryContextMenu: { [weak self] anchorView, event, direction, showFullHistory, debugSource in
                    self?.showFocusHistoryContextMenu(
                        anchorView: anchorView,
                        event: event,
                        direction: direction,
                        showFullHistory: showFullHistory,
                        debugSource: debugSource
                    ) ?? false
                }
        )
#if DEBUG
        routerSeams.debugManagerToken = { [weak self] manager in
            self?.debugManagerToken(manager) ?? "nil"
        }
        routerSeams.debugWindowToken = { [weak self] window in
            self?.debugWindowToken(window) ?? "nil"
        }
        routerSeams.debugContextToken = { [weak self] context in
            self?.debugContextToken(context) ?? "nil"
        }
        routerSeams.debugRouteSnapshot = { [weak self] event in
            self?.debugShortcutRouteSnapshot(event: event) ?? ""
        }
#endif
        environment.mainWindowRouter.configureHostSeams(routerSeams)
        Self.shared = self
        AgentChatThemeSync.start()
        // Inverts the surface registry's legacy AppDelegate.shared reach-up:
        // the registry asks this delegate (via MainWindowRouteRetiring) to
        // sweep recoverable main-window routes after a surface unregisters.
        GhosttyApp.terminalSurfaceRegistry.attachRouteRetirer(self)
        // Inverts TerminalSurface.owningWorkspace()'s legacy AppDelegate.shared
        // reach-up: the surface resolves its owning Workspace through this
        // injected WorkspaceResolving seam instead of the global singleton.
        GhosttyApp.workspaceResolver = self
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        externalURLOpenRouter.open(urls: urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if hasVisibleMainTerminalWindow() {
            _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)
            return true
        }
        if mainWindowVisibilityController.showApplicationWindows(
            windows: mainWindowsForVisibilityController(),
            reason: .applicationReopen,
            activation: .none
        ) == nil {
            _ = ensureInitialMainWindowIfNeeded()
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = isRunningUnderXCTest(env)
        let telemetryEnabled = telemetrySettings.enabledForCurrentLaunch
        StartupBreadcrumbLog.append(
            "appDelegate.didFinish.begin",
            fields: [
                "xctest": isRunningUnderXCTest ? "1" : "0",
                "telemetry": telemetryEnabled ? "1" : "0"
            ]
        )
        appIconLaunchReporter.markDidFinishLaunching()
        // Construct + own the external-control composition owner at the
        // composition root (de-singletonization stage b72): the type no longer
        // self-vivifies a `static let shared`.
        ensureTerminalControlInstalled()
        // Construct + own the recently-closed-item history store at the
        // composition root (de-singletonization stage b73): the type no longer
        // self-vivifies a `static let shared`.
        ensureClosedItemHistoryInstalled()
        AppearanceSettingsUserDefaultsObserver.shared.startObserving()
        BrowserSystemProxyWatcher.shared.startObserving()
        if isRunningUnderXCTest {
            NSApp.setActivationPolicy(.regular)
        } else {
            MenuBarOnlySettings.normalizeLegacyStoredPreference()
            menuBarExtraCoordinator.syncActivationPolicy()
        }
        StartupBreadcrumbLog.append("appDelegate.didFinish.activationPolicy.synced")

        // Drive `unregisterMainWindow` off the window-identity coordinator's
        // close broadcast (the close-observer responsibility drained out of
        // `MainWindowContext`). Started here at the composition root, before any
        // window registers.
        windowLifecycle.observeWindowCoordinatorClosures()

        // Prewarm the shared restorable-agent index off the main thread so the first
        // tab/workspace/window close after launch reads a warm cache instead of paying a
        // synchronous RestorableAgentSessionIndex.load() on the main thread. See
        // closedPanelHistoryEntry.
        if !isRunningUnderXCTest {
            SharedLiveAgentIndex.shared.scheduleRefreshIfStale()
        }

        claimAuthCallbackURLSchemes()
        StartupBreadcrumbLog.append("appDelegate.didFinish.authSchemes.claimed")

        // Install the Feed (workstream) store. Separate from the transport
        // wiring: the store is a plain singleton here, and the socket
        // `feed.*` V2 verbs in `TerminalController` push into it directly
        // via `FeedCoordinator`.
        FeedCoordinator.shared.install(
            store: WorkstreamStore(
                transport: NullWorkstreamTransport(),
                persistence: WorkstreamPersistence(fileURL: WorkstreamPersistence.defaultFileURL())
            )
        )
        StartupBreadcrumbLog.append("appDelegate.didFinish.feedStore.installed")
        Task { @MainActor in
            await FeedCoordinator.shared.store?.start()
#if DEBUG
            installFeedSidebarUITestRecorderIfNeeded()
#endif
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleThemesReloadNotification(_:)),
            name: .cmuxThemesReloadConfig,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReactGrabDidCopySelection(_:)),
            name: .reactGrabDidCopySelection,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFeedRequestFocus(_:)),
            name: .feedRequestFocus,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFeedRequestSendText(_:)),
            name: .feedRequestSendText,
            object: nil
        )

#if DEBUG
        // UI tests run on a shared VM user profile, so persisted shortcuts can drift and make
        // key-equivalent routing flaky. Force defaults for deterministic tests.
        if isRunningUnderXCTest {
            SystemWideHotkeySettings.reset()
            KeyboardShortcutSettings.resetAll()
        }
#endif

#if DEBUG
        // Writes the launch diagnostics, installs the injected stall / turn
        // probes (pointing `CmuxTypingTiming.turnProfiler` at the same profiler
        // before any keystroke), and schedules the after-1s diagnostics write.
        startupUITestScaffold.installDiagnosticsProbesAndScheduleAfter1s()
#endif

        if telemetryEnabled {
            // Pre-warm locale before Sentry to avoid a startup data race.
            // Locale initialization (os.locale.ensureLocale / NSLocale._preferredLanguages)
            // on the main thread can race with Sentry's background init thread
            // calling posix.getenv, causing a SIGSEGV ~134ms after launch.
            // Forcing locale access here before SentrySDK.start eliminates the race.
            // Related to: #836
            _ = Locale.current
            _ = NSLocale.preferredLanguages

            StartupBreadcrumbLog.append("appDelegate.didFinish.sentry.begin")
            SentrySDK.start { options in
                options.dsn = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416"
                #if DEBUG
                options.environment = "development"
                options.debug = true
                #else
                options.environment = "production"
                options.debug = false
                #endif
                options.sendDefaultPii = false

                // Performance tracing is disabled. The auto-instrumented root
                // `SentryTransaction.trace` serializes its `data` / `tags` /
                // `description` into the payload *after* `beforeSend` runs, and
                // the root tracer is not reachable through the public Sentry API,
                // so those fields cannot be scrubbed. Disabling transactions
                // removes that un-scrubbable egress path while keeping crash,
                // error, and app-hang reporting (which are independent of the
                // trace sample rate). cmux does not consume these performance
                // traces today.
                options.tracesSampleRate = 0.0
                // Keep app-hang tracking enabled, but avoid reporting short main-thread stalls
                // as hangs in normal user interaction flows.
                options.appHangTimeoutInterval = 8.0
                // Attach stack traces to all events
                options.attachStacktrace = true
                // Avoid recursively capturing failed requests from Sentry's own ingestion endpoint.
                options.enableCaptureFailedRequests = false
                // Redact file paths, emails, and secrets from every outgoing
                // event, breadcrumb, and (belt-and-suspenders, if tracing is ever
                // re-enabled) child performance span before it leaves the device.
                let scrubber = SentryEventScrubber()
                options.beforeSend = { event in scrubber.scrub(event) }
                options.beforeBreadcrumb = { breadcrumb in scrubber.scrub(breadcrumb) }
                options.beforeSendSpan = { span in scrubber.scrub(span) }
            }
            StartupBreadcrumbLog.append("appDelegate.didFinish.sentry.complete")
        }

        if telemetryEnabled && !isRunningUnderXCTest {
            StartupBreadcrumbLog.append("appDelegate.didFinish.posthog.begin")
            PostHogAnalytics.shared.startIfNeeded()
            StartupBreadcrumbLog.append("appDelegate.didFinish.posthog.complete")
        }

        let forceDuplicateLaunchObserver = env["CMUX_UI_TEST_ENABLE_DUPLICATE_LAUNCH_OBSERVER"] == "1"

        // UI tests frequently time out waiting for the main window if we do heavyweight
        // LaunchServices registration / single-instance enforcement synchronously at startup.
        // Skip these during XCTest (the app-under-test) so the window can appear quickly.
        if !isRunningUnderXCTest {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                StartupBreadcrumbLog.append("appDelegate.singleInstance.async.begin")
                self.scheduleLaunchServicesBundleRegistration()
                StartupBreadcrumbLog.append("appDelegate.singleInstance.launchServices.scheduled")
                self.enforceSingleInstance()
                self.observeDuplicateLaunches()
                StartupBreadcrumbLog.append("appDelegate.singleInstance.async.complete")
            }
        } else if forceDuplicateLaunchObserver {
            // Some UI regressions specifically exercise launch-observer behavior while still
            // running under XCTest. Allow an explicit opt-in for those cases only.
            DispatchQueue.main.async { [weak self] in
                self?.observeDuplicateLaunches()
            }
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        disableNativeTabbingShortcut()
        if !isRunningUnderXCTest {
            ensureApplicationIcon()
        }
        if !isRunningUnderXCTest {
            configureUserNotifications()
            menuBarExtraCoordinator.installMenuBarVisibilityObserver()
            menuBarExtraCoordinator.syncApplicationPresentationPreferences()
            updateController.actionDelegate = self
            updateController.startUpdaterIfNeeded()
        }
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installMainWindowKeyObserver()
        refreshGhosttyGotoSplitShortcuts()
        installGhosttyConfigObserver()
        installWindowResponderSwizzles()
        installBrowserAddressBarFocusObservers()
        installShortcutMonitor()
        installShortcutDefaultsObserver()
        if !isRunningUnderXCTest {
            GlobalSearchCoordinator.shared.start()
            sentryStartMemoryContextRefresh()
        }
        systemWideHotkeyController.actionHandler = self
        systemWideHotkeyController.start()
        AgentHibernationController.shared.start()
        RendererRealizationController.shared.start()
        NSApp.servicesProvider = self

        StartupBreadcrumbLog.append("appDelegate.didFinish.bootstrap.begin")
        scheduleInitialMainWindowBootstrap(debugSource: "didFinishLaunching")
        StartupBreadcrumbLog.append("appDelegate.didFinish.complete")
#if DEBUG
        // Env-gated launch UI-test actions: update-check mock/trigger, and (under
        // XCTest) the browser import-hint defaults plus the force-window /
        // browser-import scheduled hops. The scaffold owns the gates + schedule;
        // each live action is an ``StartupUITestScaffoldDriving`` witness below.
        startupUITestScaffold.runLaunchScaffolds(environment: env, isRunningUnderXCTest: isRunningUnderXCTest)
#endif
    }

#if DEBUG
    /// Writes the display/render/socket/portal diagnostics payload for `stage`.
    ///
    /// Forwards to ``DisplayDiagnosticsUITestRecorder``, which owns the
    /// byte-identical payload assembly and file I/O; this app-target shim only
    /// supplies the live state through ``UITestDiagnosticsProviding``.
    func writeUITestDiagnosticsIfNeeded(stage: String) {
        displayDiagnosticsUITestRecorder.write(stage: stage)
    }

    private func currentUITestRenderDiagnostics() -> UITestDiagnosticsSnapshot.Stats? {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        let terminalPanel: TerminalPanel? = {
            if let focusedPanelId = workspace.focusedPanelId,
               let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
                return terminalPanel
            }
            if let focusedTerminalPanel = workspace.focusedTerminalPanel {
                return focusedTerminalPanel
            }
            return workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
        }()

        guard let terminalPanel else { return nil }
        let stats = terminalPanel.hostedView.debugRenderStats()
        return UITestDiagnosticsSnapshot.Stats(
            panelID: terminalPanel.id,
            drawCount: stats.drawCount,
            presentCount: stats.presentCount,
            lastPresentTime: stats.lastPresentTime,
            windowVisible: stats.windowOcclusionVisible,
            appIsActive: stats.appIsActive,
            desiredFocus: stats.desiredFocus,
            isFirstResponder: stats.isFirstResponder
        )
    }

    /// Gathers the live diagnostics state for ``DisplayDiagnosticsUITestRecorder``.
    ///
    /// Applies each section's environment gate so the recorder emits exactly
    /// the legacy key set: the render/socket/portal sub-snapshots are `nil`
    /// when their gate (`CMUX_UI_TEST_DISPLAY_RENDER_STATS` /
    /// `CMUX_UI_TEST_SOCKET_SANITY` / `CMUX_UI_TEST_PORTAL_STATS`) is unset.
    fileprivate func gatherUITestDiagnosticsSnapshot(
        environment env: [String: String]
    ) -> UITestDiagnosticsSnapshot {
        let windows = NSApp.windows.map { window in
            UITestDiagnosticsSnapshot.Window(
                identifier: window.identifier?.rawValue ?? "",
                isVisible: window.isVisible,
                screenDisplayID: window.screen?.cmuxDisplayID
            )
        }
        let presentDisplayIDs = Set(NSScreen.screens.compactMap { $0.cmuxDisplayID })

        return UITestDiagnosticsSnapshot(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            isRunningUnderXCTest: isRunningUnderXCTest(env),
            windows: windows,
            targetDisplayID: env["CMUX_UI_TEST_TARGET_DISPLAY_ID"] ?? "",
            presentDisplayIDs: presentDisplayIDs,
            render: uiTestRenderDiagnosticsSection(environment: env),
            socket: uiTestSocketDiagnosticsSection(environment: env),
            portal: uiTestPortalDiagnosticsSection(environment: env),
            systemUptime: ProcessInfo.processInfo.systemUptime
        )
    }

    private func uiTestRenderDiagnosticsSection(
        environment env: [String: String]
    ) -> UITestDiagnosticsSnapshot.Render? {
        guard env["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return nil }
        guard let stats = currentUITestRenderDiagnostics() else { return .unavailable }
        return .available(stats)
    }

    private func uiTestSocketDiagnosticsSection(
        environment env: [String: String]
    ) -> UITestDiagnosticsSnapshot.Socket? {
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return nil }

        guard let config = socketListenerConfigurationIfEnabled() else {
            return .disabled(expectedPath: env["CMUX_SOCKET_PATH"] ?? "")
        }

        let socketPath = terminalControl.activeSocketPath(preferredPath: config.path)
        let health = terminalControl.socketListenerHealth(expectedSocketPath: socketPath)
        let pingResponse = health.isHealthy
            ? socketTransport.probeCommand("ping", at: socketPath, timeout: 1.0)
            : nil
        let isReady = health.isHealthy && pingResponse == "PONG"
        var failureSignals = health.failureSignals
        if health.isHealthy && pingResponse != "PONG" {
            failureSignals.append("ping_timeout")
        }

        return UITestDiagnosticsSnapshot.Socket(
            isEnabled: true,
            expectedPath: socketPath,
            mode: config.mode.rawValue,
            isReady: isReady,
            pingResponse: pingResponse ?? "",
            isRunning: health.isRunning,
            acceptLoopAlive: health.acceptLoopAlive,
            socketPathMatches: health.socketPathMatches,
            socketPathExists: health.socketPathExists,
            socketPathOwnedByListener: health.socketPathOwnedByListener,
            failureSignals: failureSignals.joined(separator: ",")
        )
    }

    private func uiTestPortalDiagnosticsSection(
        environment env: [String: String]
    ) -> [String: String]? {
        guard env["CMUX_UI_TEST_PORTAL_STATS"] == "1" else { return nil }

        let stats = TerminalWindowPortalRegistry.debugPortalStats()
        var portal: [String: String] = [:]
        portal["portal_count"] = String(uiTestDiagnosticDescribing: stats["portal_count"])
        portal["portal_hosted_mapping_count"] = String(uiTestDiagnosticDescribing: stats["hosted_mapping_count"])
        portal["portal_guarded_bind_blocked_count"] = String(uiTestDiagnosticDescribing: stats["guarded_bind_blocked_count"])
        if let totals = stats["totals"] as? [String: Any] {
            for (key, value) in totals {
                portal["portal_\(key)"] = String(uiTestDiagnosticDescribing: value)
            }
        }
        return portal
    }

    private func moveUITestWindowToTargetDisplayIfNeeded(attempt: Int = 0) {
        let env = ProcessInfo.processInfo.environment
        guard let rawDisplayID = env["CMUX_UI_TEST_TARGET_DISPLAY_ID"],
              let targetDisplayID = UInt32(rawDisplayID) else {
            return
        }

        guard let screen = NSScreen.screens.first(where: { $0.cmuxDisplayID == targetDisplayID }) else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
                }
            }
            self.writeUITestDiagnosticsIfNeeded(stage: "targetDisplayMissing")
            return
        }

        guard let window = NSApp.windows.first else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
                }
            }
            self.writeUITestDiagnosticsIfNeeded(stage: "targetDisplayNoWindow")
            return
        }

        let visibleFrame = screen.visibleFrame
        let width = min(window.frame.width, max(visibleFrame.width - 80, 480))
        let height = min(window.frame.height, max(visibleFrame.height - 80, 360))
        let frame = NSRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2),
            width: width,
            height: height
        ).integral

        window.setFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if window.screen?.cmuxDisplayID != targetDisplayID, attempt < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.moveUITestWindowToTargetDisplayIfNeeded(attempt: attempt + 1)
            }
            return
        }
        self.writeUITestDiagnosticsIfNeeded(stage: "afterMoveToTargetDisplay")
    }

    /// ``UITestDiagnosticsProviding`` witness: gathers the live diagnostics
    /// snapshot for ``DisplayDiagnosticsUITestRecorder``. The conformance is
    /// declared at file scope below.
    func currentUITestDiagnosticsSnapshot(environment: [String: String]) -> UITestDiagnosticsSnapshot {
        gatherUITestDiagnosticsSnapshot(environment: environment)
    }
#endif

    func applicationWillBecomeActive(_ notification: Notification) {
        // `applicationWillBecomeActive(_:)` stays the `NSApplicationDelegate`
        // requirement; the pre-activation visibility sequencing is owned by
        // `ApplicationActivationCoordinator` and reached through the
        // `ApplicationActivationHost` seam this delegate conforms to.
        activationCoordinator.applicationWillBecomeActive()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // `applicationDidBecomeActive(_:)` stays the `NSApplicationDelegate`
        // requirement; the visibility-restore + telemetry + notification-activation
        // reconcile sequencing is owned by `ApplicationActivationCoordinator` and
        // reached through the `ApplicationActivationHost` seam.
        activationCoordinator.applicationDidBecomeActive()
    }

    // `hasQuitConfirmationDirtyWorkspaces()` lives in
    // `QuitConfirmationAlertPresenter.swift` (it also folds in the per-window
    // Dock dirty check), and witnesses the `ApplicationTerminationHost`
    // requirement from there.

    func pendingTerminateReply(isAwaitingTerminateKills: Bool) -> NSApplication.TerminateReply? {
        Self.pendingTerminateReply(
            isAwaitingTerminateKills: isAwaitingTerminateKills,
            hasActiveQuitConfirmation: activeQuitConfirmationAlertPresenter != nil,
            activeQuitConfirmationOwnsTerminateRequest: activeQuitConfirmationOwnsTerminateRequest
        )
    }

    func presentQuitConfirmation(
        ownsTerminateRequest: Bool,
        completion: @escaping @MainActor (NSApplication.ModalResponse, NSControl.StateValue) -> Void
    ) {
        guard activeQuitConfirmationAlertPresenter == nil else { return }
        let presenter = QuitConfirmationAlertPresenter { [weak self] response, suppressionState in
            guard let self else { return }
            self.activeQuitConfirmationAlertPresenter = nil
            self.activeQuitConfirmationOwnsTerminateRequest = false
            completion(response, suppressionState)
        }
        activeQuitConfirmationOwnsTerminateRequest = ownsTerminateRequest
        activeQuitConfirmationAlertPresenter = presenter
        presenter.present()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let buildFlavor = BuildFlavor.current
        return terminateReply.applicationShouldTerminate(
            isDevBuild: buildFlavor == .dev,
            buildFlavorRawValue: buildFlavor.rawValue
        )
    }

    // Internal (not private) so the `ApplicationTerminationHost` conformance in
    // `AppDelegate+ApplicationTerminationHost.swift` can witness it.
    @discardableResult
    func closeAllWebInspectorsBeforeAppTeardown() -> Int {
        WebViewInspectorTeardown.closeAllInspectors(in: NSApp.windows)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // `applicationWillTerminate(_:)` stays the `NSApplicationDelegate`
        // requirement; the ordered teardown sequence is owned by
        // `ApplicationTerminateReplyCoordinator` and reached through the
        // `ApplicationTerminationHost` seam this delegate conforms to.
        terminateReply.performTeardown()
        unregisterDisplayReconfigurationCallbackIfNeeded()
        if let displayReconfigurationObserver {
            NotificationCenter.default.removeObserver(displayReconfigurationObserver)
            self.displayReconfigurationObserver = nil
        }
        if let screenChangeReconcileObserver {
            NotificationCenter.default.removeObserver(screenChangeReconcileObserver)
            self.screenChangeReconcileObserver = nil
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        // `applicationWillResignActive(_:)` stays the `NSApplicationDelegate`
        // requirement; the terminate guard + chord-clear + session-snapshot
        // sequencing is owned by `ApplicationActivationCoordinator` and reached
        // through the `ApplicationActivationHost` seam.
        activationCoordinator.applicationWillResignActive()
    }

    func persistSessionForUpdateRelaunch() {
        terminateReply.persistForRelaunch()
    }

    func configure(
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore,
        keyboardShortcutSettingsObserver: KeyboardShortcutSettingsObserver,
        taskManagerWindowController: TaskManagerWindowController,
        sidebarState: SidebarState,
        settingsRuntime: SettingsRuntime,
        auth: MacAuthComposition
    ) {
        self.tabManager = tabManager
        self.settingsRuntime = settingsRuntime
        self.notificationStore = notificationStore
        // De-singletonization stage b73: the cmuxApp `@StateObject` owns the
        // single `TerminalNotificationStore`; record composition-root ownership so
        // the transitional `TerminalNotificationStore.shared` accessor used by the
        // tail call sites resolves to this same injected instance.
        TerminalNotificationStore.installCompositionRootInstance(notificationStore)
        // De-singletonization stage b76: the cmuxApp `@StateObject` owns the
        // single `KeyboardShortcutSettingsObserver`; record composition-root
        // ownership so the transitional `KeyboardShortcutSettingsObserver.shared`
        // accessor read by the remaining SwiftUI view sites resolves to this same
        // injected instance instead of a self-vivified eager singleton.
        KeyboardShortcutSettingsObserver.installCompositionRootInstance(keyboardShortcutSettingsObserver)
        // De-singletonization stage (settings-file store): `CmuxSettingsFileStore`
        // no longer self-vivifies an eager `static let shared`. Record
        // composition-root ownership of the single instance now held by
        // `KeyboardShortcutSettings.settingsFileStore` (seeded from `.shared`
        // earlier in app init) so the transitional `CmuxSettingsFileStore.shared`
        // accessor resolves to that same object.
        CmuxSettingsFileStore.installCompositionRootInstance(KeyboardShortcutSettings.settingsFileStore)
        // De-singletonization: the cmuxApp `@State` owns the single
        // `TaskManagerWindowController`; record composition-root ownership so the
        // transitional `TaskManagerWindowController.shared` accessor read by the
        // tail call sites (menu-bar extra, `openTaskManagerWindow`, the View
        // command palette) resolves to this same injected instance instead of a
        // self-vivified lazy singleton.
        TaskManagerWindowController.installCompositionRootInstance(taskManagerWindowController)
        environment.mainWindowRouter.activeSidebarState = sidebarState
        environment.auth = auth
        VMClient.bootstrap(auth: auth.coordinator)
        RemotesClient.bootstrap(auth: auth.coordinator)
        PhonePushClient.shared.configure(auth: auth.coordinator)
        MobileHostService.shared.configure(auth: auth.coordinator)
        DeviceRegistryClient.shared.configure(auth: auth.coordinator)
        PresenceHeartbeatClient.shared.configure(auth: auth.coordinator)
        // DEV-only: auto-publish this Mac's attach route to the signed-in user's
        // paired-Macs backup so a fresh dev iOS build restores it. No-op on
        // Release or when the flag is off.
        MacPairedMacBackupPublisher.shared.configure(auth: auth.coordinator)
        terminalControl.attachAuth(coordinator: auth.coordinator, browserSignIn: auth.browserSignIn)
        terminalControl.agentChatTranscriptService = agentChatTranscriptService
        auth.start()
        ensureMobileWorkspaceListObserver(for: tabManager)
        MobileTerminalRenderObserver.shared.start()
        agentChatTranscriptService.start()
        installMobileHostSettingsObserver()
        scheduleGhosttyCrashBreadcrumbIfNeeded(notificationStore: notificationStore)
        startPaneMemoryGuardrailIfNeeded(notificationStore: notificationStore)
        disableSuddenTerminationIfNeeded()
        installLifecycleSnapshotObserversIfNeeded()
        // Seed so the first display change after launch can restore geometry.
        lastAppliedConfigurationSignature = currentDisplayConfigurationSignature()
        lastVisibleFrameFitTopologySignature = MainWindowVisibleFrameFitCore()
            .trustedTopologySignature(of: currentDisplayGeometries().available)
        prepareStartupSessionSnapshotIfNeeded()
        startSessionAutosaveTimerIfNeeded()
#if DEBUG
        installLaunchUITestRecorders()
        setupTerminalViewportUITestIfNeeded()
        setupMultiWindowNotificationsUITestIfNeeded()
        setupDisplayResolutionUITestDiagnosticsIfNeeded()
        setupPortalStatsUITestDiagnosticsIfNeeded()

        let env = ProcessInfo.processInfo.environment
        if isRunningUnderXCTest(env) || env["CMUX_UI_TEST_MODE"] == "1" {
            scheduleUITestSocketSanityCheckIfNeeded()
        }
        // Best-effort one-time migration: a value previously stored in the
        // legacy ~/.config/cmux/dev-window-display file moves into the shared
        // cmux.json (app.devWindowDisplay) so an existing dev-display default
        // keeps working. No-op when already set or the legacy file is absent.
        Task { await DevWindowDisplayDefault.migrateLegacyFileIfNeeded(runtime: settingsRuntime) }
#endif
    }

    /// Starts the per-pane runaway-memory guardrail: a background timer that
    /// attributes each pane's process-tree memory by controlling tty and warns
    /// (sidebar badge + dismissible banner with a kill action) before a single
    /// leaking pane can OOM-suspend the whole app (issue #6313).
    private func startPaneMemoryGuardrailIfNeeded(notificationStore: TerminalNotificationStore) {
        let guardrail = environment.paneMemoryGuardrail
        guardrail.paneProvider = { [weak self] in
            self?.paneMemoryGuardrailDescriptors() ?? []
        }
        guardrail.onWarnedWorkspacesChanged = { [weak notificationStore] ids in
            notificationStore?.sidebarUnread.setMemoryWarningWorkspaceIds(ids)
        }
        guardrail.onRequestClosePane = { [weak self] workspaceId, panelId in
            _ = self?.closePaneForMemoryGuardrail(workspaceId: workspaceId, panelId: panelId)
        }
        guardrail.start()
        startMemoryPressureMonitorIfNeeded()
    }

    private func scheduleGhosttyCrashBreadcrumbIfNeeded(notificationStore: TerminalNotificationStore) {
        guard !didScheduleGhosttyCrashBreadcrumbCheck else { return }
        didScheduleGhosttyCrashBreadcrumbCheck = true

        ghosttyCrashBreadcrumbTask = Task { [weak self, weak notificationStore] in
            defer { self?.ghosttyCrashBreadcrumbTask = nil }
            guard let pendingCrash = await GhosttyCrashBreadcrumb.pendingCrashFromDefaultStorage(),
                  !Task.isCancelled,
                  let notificationStore else { return }
            notificationStore.addNotification(
                tabId: GhosttyCrashBreadcrumb.notificationTabId,
                surfaceId: nil,
                title: String(
                    localized: "crashBreadcrumb.title",
                    defaultValue: "cmux crashed during your last session"
                ),
                subtitle: String(
                    localized: "crashBreadcrumb.subtitle",
                    defaultValue: "Diagnostic file saved"
                ),
                body: String(
                    localized: "crashBreadcrumb.body",
                    defaultValue: "Diagnostic file saved. Click to reveal it in Finder."
                ),
                clickAction: .revealInFinder(path: pendingCrash.fileURL.path)
            )
            GhosttyCrashBreadcrumb.markShown(pendingCrash)
        }
    }

#if DEBUG
    /// Schedules the socket-sanity diagnostics check once; the
    /// ``SocketSanityUITestRecorder`` owns the delayed health probe, ping,
    /// listener restart, and diagnostics-stage writes.
    private func scheduleUITestSocketSanityCheckIfNeeded() {
        let recorder = socketSanityUITestRecorder ?? SocketSanityUITestRecorder(appDelegate: self)
        socketSanityUITestRecorder = recorder
        recorder.installIfNeeded()
    }

    /// Installs the display-resolution diagnostics observers once; the
    /// ``DisplayResolutionUITestRecorder`` owns the window/screen/surface
    /// notification subscriptions and diagnostics-stage writes.
    private func setupDisplayResolutionUITestDiagnosticsIfNeeded() {
        let recorder = displayResolutionUITestRecorder ?? DisplayResolutionUITestRecorder(appDelegate: self)
        displayResolutionUITestRecorder = recorder
        recorder.installIfNeeded()
    }

    /// Installs the portal-stats diagnostics observer once; the
    /// ``PortalStatsUITestRecorder`` owns the portal-visibility subscription and
    /// diagnostics-stage writes.
    private func setupPortalStatsUITestDiagnosticsIfNeeded() {
        let recorder = portalStatsUITestRecorder ?? PortalStatsUITestRecorder(appDelegate: self)
        portalStatsUITestRecorder = recorder
        recorder.installIfNeeded()
    }

    /// Installs the ``FeedSidebarUITestRecorder`` once; the recorder owns the
    /// reveal/push flow and byte-faithful capture-file writes.
    private func installFeedSidebarUITestRecorderIfNeeded() {
        let recorder = feedSidebarUITestRecorder ?? FeedSidebarUITestRecorder(appDelegate: self)
        feedSidebarUITestRecorder = recorder
        recorder.installIfNeeded()
    }
#endif

    private func prepareStartupSessionSnapshotIfNeeded() {
        guard !didPrepareStartupSessionSnapshot else { return }
        didPrepareStartupSessionSnapshot = true
        Self.windowGeometryStore.removeLegacy(defaults: .standard)
        syncManualRestoreSnapshotCachePruningCrashDiagnostics()
        let sanitizedStartupSnapshot = loadStartupSessionSnapshotPruningCrashDiagnostics()
        guard SessionRestorePolicy().shouldAttemptRestore else { return }
        startupSessionSnapshot = sanitizedStartupSnapshot
    }

    private func loadStartupSessionSnapshotPruningCrashDiagnostics() -> AppSessionSnapshot? {
        guard let primaryURL = sessionSnapshotStore.defaultSnapshotFileURL() else { return nil }
        switch sessionSnapshotStore.loadOutcome(fileURL: primaryURL) {
        case .loaded(let snapshot):
            if let prunedSnapshot = SessionPersistencePolicy
                .pruningCmuxCrashDiagnosticWindows(from: snapshot)
                .snapshot {
                return prunedSnapshot
            }
            return loadManualRestoreSessionSnapshotPruningCrashDiagnostics()
        case .missing:
            if Self.hasCrashOnlyPrimarySnapshotRemovalMarker() {
                return loadManualRestoreSessionSnapshotPruningCrashDiagnostics()
            }
            return nil
        case .unusable:
            return loadManualRestoreSessionSnapshotPruningCrashDiagnostics()
        }
    }

    private func loadManualRestoreSessionSnapshotPruningCrashDiagnostics() -> AppSessionSnapshot? {
        sessionSnapshotStore.loadReopenSessionSnapshot(fileURL: nil).flatMap {
            SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: $0).snapshot
        }
    }

    private func persistedWindowGeometry(defaults: UserDefaults = .standard) -> PersistedWindowGeometry? {
        Self.windowGeometryStore.load(defaults: defaults)
    }

    private func persistWindowGeometry(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?,
        defaults: UserDefaults = .standard
    ) {
        // A nil payload (no frame) still clears the legacy keys, as before.
        guard let payload = Self.persistedWindowGeometryPayload(frame: frame, display: display) else {
            Self.windowGeometryStore.removeLegacy(defaults: defaults)
            return
        }
        Self.windowGeometryStore.save(payload, defaults: defaults)
    }

    /// Builds the `PersistedWindowGeometry` payload, or nil when there is no
    /// frame. Encode/decode and `UserDefaults` access live in the store.
    private nonisolated static func persistedWindowGeometryPayload(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?
    ) -> PersistedWindowGeometry? {
        guard let frame else { return nil }
        return PersistedWindowGeometry(
            version: persistedWindowGeometrySchemaVersion,
            frame: frame,
            display: display
        )
    }

    private nonisolated static func encodedPersistedWindowGeometryData(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?
    ) -> Data? {
        persistedWindowGeometryPayload(frame: frame, display: display)
            .flatMap { windowGeometryStore.encode($0) }
    }

    nonisolated static func decodedPersistedWindowGeometryData(_ data: Data) -> PersistedWindowGeometry? {
        windowGeometryStore.decode(data)
    }

    private func persistWindowGeometry(from window: NSWindow?) {
        guard let window else { return }
        persistWindowGeometry(
            frame: SessionRectSnapshot(window.frame),
            display: displaySnapshot(for: window)
        )
    }

    /// Reads live `NSScreen` / `NSWindow` state into ``SessionDisplayGeometry``
    /// values, lifted to ``CmuxWindowing/DisplayGeometryReader``. A pure value,
    /// so a shared constant rather than per-call instantiation.
    private nonisolated static let displayGeometryReader = DisplayGeometryReader()

    func currentDisplayGeometries() -> (available: [SessionDisplayGeometry], fallback: SessionDisplayGeometry?) {
        Self.displayGeometryReader.currentDisplayGeometries()
    }

    private func resolvedPersistedWindowGeometryFrame() -> NSRect? {
        let displays = currentDisplayGeometries()
        let fallbackGeometry = persistedWindowGeometry()
        return Self.resolvedWindowFrame(
            from: fallbackGeometry?.frame,
            display: fallbackGeometry?.display,
            availableDisplays: displays.available,
            fallbackDisplay: displays.fallback
        )
    }

    @discardableResult
    private func attemptStartupSessionRestoreIfNeeded(primaryWindow: NSWindow) -> Bool {
        guard !didAttemptStartupSessionRestore else { return false }
        didAttemptStartupSessionRestore = true
        // Flush deferred navigation links unless additional restored windows remain pending.
        defer {
            if !isApplyingSessionRestore {
                flushPendingStartupNavigationURLRequests()
            }
        }
        guard !didHandleExplicitOpenIntentAtStartup else { return false }
        guard let primaryContext = contextForMainTerminalWindow(primaryWindow) else { return false }

        let startupSnapshot = startupSessionSnapshot
        let primaryWindowSnapshot = startupSnapshot?.windows.first
        if let primaryWindowSnapshot {
            isApplyingSessionRestore = true
#if DEBUG
            cmuxDebugLog(
                "session.restore.start windows=\(startupSnapshot?.windows.count ?? 0) " +
                    "primaryFrame={\(primaryWindowSnapshot.frame?.debugLogDescription ?? "nil")} " +
                    "primaryDisplay={\(primaryWindowSnapshot.display?.debugLogDescription ?? "nil")}"
            )
#endif
            applySessionWindowSnapshot(
                primaryWindowSnapshot,
                to: primaryContext,
                window: primaryWindow
            )
        } else {
            let displays = currentDisplayGeometries()
            let fallbackGeometry = persistedWindowGeometry()
            if let restoredFrame = Self.resolvedStartupPrimaryWindowFrame(
                primarySnapshot: nil,
                fallbackFrame: fallbackGeometry?.frame,
                fallbackDisplaySnapshot: fallbackGeometry?.display,
                availableDisplays: displays.available,
                fallbackDisplay: displays.fallback
            ) {
                primaryWindow.setFrame(restoredFrame, display: true)
            }
        }

        guard let startupSnapshot else { return false }

        let additionalWindows = Array(startupSnapshot
            .windows
            .dropFirst()
            .prefix(max(0, SessionPersistencePolicy.maxWindowsPerSnapshot - 1)))
#if DEBUG
        for (index, windowSnapshot) in additionalWindows.enumerated() {
            cmuxDebugLog(
                "session.restore.enqueueAdditional idx=\(index + 1) " +
                    "frame={\(windowSnapshot.frame?.debugLogDescription ?? "nil")} " +
                    "display={\(windowSnapshot.display?.debugLogDescription ?? "nil")}"
            )
        }
#endif
        if !additionalWindows.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for windowSnapshot in additionalWindows {
                    _ = self.createMainWindow(sessionWindowSnapshot: windowSnapshot)
                }
                self.completeSessionRestoreOperation(isManualReopen: false)
            }
        } else {
            completeSessionRestoreOperation(isManualReopen: false)
        }
        return true
    }

    private func completeSessionRestoreOperation(isManualReopen: Bool) {
        startupSessionSnapshot = nil
        isApplyingSessionRestore = false
        if isScreenChangeCaptureSuppressed {
            scheduleScreenChangeReconcileWhenIdle()
        }
        flushPendingStartupNavigationURLRequests()
        if Self.sessionPersistenceDecisionPolicy.shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: isManualReopen) {
            // Auto-resume input can be queued before tmux has spawned; preserve
            // restored process-detected bindings until a later live scan.
            _ = saveSessionSnapshot(includeScrollback: false)
        }
    }

    @discardableResult
    func reopenPreviousSession(shouldActivate: Bool = true) -> Bool {
        guard let snapshot = sessionSnapshotStore.loadReopenSessionSnapshot(fileURL: nil) else {
            return false
        }
        return restorePreviousSessionSnapshot(snapshot, shouldActivate: shouldActivate)
    }

    @discardableResult
    func restorePreviousSessionSnapshot(
        _ snapshot: AppSessionSnapshot,
        shouldActivate: Bool = true
    ) -> Bool {
        let snapshotWindows = Array(
            snapshot.windows.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
        )
        guard !snapshotWindows.isEmpty else { return false }

        isApplyingSessionRestore = true
        startupSessionSnapshot = nil
        didAttemptStartupSessionRestore = true
        var createdWindowIds: [UUID] = []

        for windowSnapshot in snapshotWindows {
            let windowId = createMainWindow(
                sessionWindowSnapshot: windowSnapshot,
                shouldActivate: false,
                excludingStableIdentitiesFromSessionSnapshot: liveStableIdentitySet()
            )
            createdWindowIds.append(windowId)
        }

        completeSessionRestoreOperation(isManualReopen: true)

        if shouldActivate,
           let primaryWindowId = createdWindowIds.first,
           let primaryWindow = mainWindow(for: primaryWindowId) {
            primaryWindow.makeKeyAndOrderFront(nil)
            setActiveMainWindow(primaryWindow)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }

        return true
    }

    private func applySessionWindowSnapshot(
        _ snapshot: SessionWindowSnapshot,
        to context: RegisteredMainWindow,
        window: NSWindow?
    ) {
#if DEBUG
        cmuxDebugLog(
            "session.restore.apply window=\(context.windowId.uuidString.prefix(8)) " +
                "liveWin=\(window?.windowNumber ?? -1) " +
                "snapshotFrame={\(snapshot.frame?.debugLogDescription ?? "nil")} " +
                "snapshotDisplay={\(snapshot.display?.debugLogDescription ?? "nil")}"
        )
#endif
        context.tabManager.restoreSessionSnapshot(snapshot.tabManager)
        // Seed the in-memory per-config ring from the restored snapshot so the
        // window can return to remembered frames on later configuration switches.
        if let configFrames = snapshot.configFrames {
            windowConfigFrames[context.windowId] = SessionConfigFrameRing(entries: configFrames)
        }
        if let originalWindowId = snapshot.windowId,
           originalWindowId != context.windowId {
            closedItemHistory.remapWorkspaceWindowIds(from: originalWindowId, to: context.windowId)
            closedItemHistory.flushPendingSaves()
        }
        let restoreSidebarState = sidebarState(for: context)
        restoreSidebarState.isVisible = snapshot.sidebar.isVisible
        restoreSidebarState.persistedWidth = CGFloat(
            SessionPersistencePolicy.sanitizedSidebarWidth(snapshot.sidebar.width)
        )
        sidebarSelectionState(for: context).selection = snapshot.sidebar.selection.sidebarSelection

        if let restoredFrame = resolvedWindowFrame(from: snapshot), let window {
            window.setFrame(restoredFrame, display: true)
#if DEBUG
            cmuxDebugLog(
                "session.restore.frameApplied window=\(context.windowId.uuidString.prefix(8)) " +
                    "applied={\(SessionRectSnapshot(window.frame).debugLogDescription)}"
            )
#endif
        }
    }

    private func resolvedWindowFrame(from snapshot: SessionWindowSnapshot?) -> NSRect? {
        let displays = currentDisplayGeometries()
        return Self.resolvedWindowFrame(
            from: snapshot,
            currentSignature: displays.available
                .displayConfigurationSignature(isMirrored: Self.displaysAreMirrored()),
            availableDisplays: displays.available,
            fallbackDisplay: displays.fallback
        )
    }

    /// Stateless session-restore frame math, lifted to
    /// ``CmuxWorkspaces/SessionWindowFrameResolver``. The minimum-size floors
    /// come from ``SessionPersistencePolicy`` so the resolver's behavior is
    /// byte-identical to the legacy in-file math. A pure value, so a shared
    /// constant rather than per-call instantiation.
    private nonisolated static let sessionWindowFrameResolver = SessionWindowFrameResolver(
        minimumWindowWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth),
        minimumWindowHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight)
    )

    /// New-window cascade-positioning math, lifted to ``CmuxWindowing/NewWindowCascadePlanner``.
    private nonisolated static let newWindowCascadePlanner = NewWindowCascadePlanner()

    /// Pure persist/autosave decision policy, lifted to
    /// ``CmuxWorkspaces/SessionPersistenceDecisionPolicy``. A stateless value,
    /// so a shared constant rather than per-call instantiation. The static
    /// decision helpers below forward to this instance so call sites (and the
    /// `SessionPersistenceTests` that drive each branch) stay byte-identical.
    // Internal (not private) so the `ApplicationActivationHost` conformance in
    // `AppDelegate+ApplicationActivationHost.swift` can witness the resign-time
    // snapshot decision.
    nonisolated static let sessionPersistenceDecisionPolicy = SessionPersistenceDecisionPolicy()

    /// Pure session-snapshot window-assembly + autosave-fingerprint folding
    /// policy, lifted to ``CmuxWorkspaces/SessionSnapshotBuilder``. A stateless
    /// value, so a shared constant. `buildSessionSnapshot` and
    /// `sessionAutosaveFingerprint` flatten the live registered-window state into
    /// the builder's value-typed inputs (the irreducible read stays here) and
    /// forward the prune / cap / fold to this instance.
    private nonisolated static let sessionSnapshotBuilder = SessionSnapshotBuilder()

    /// Maps the app's `Codable` display DTO into the resolver's runtime input.
    private nonisolated static func sessionSourceDisplaySnapshot(
        from snapshot: SessionDisplaySnapshot?
    ) -> SessionSourceDisplaySnapshot? {
        guard let snapshot else { return nil }
        return SessionSourceDisplaySnapshot(
            displayID: snapshot.displayID,
            frame: snapshot.frame?.cgRect,
            visibleFrame: snapshot.visibleFrame?.cgRect
        )
    }

    nonisolated static func resolvedStartupPrimaryWindowFrame(
        primarySnapshot: SessionWindowSnapshot?,
        fallbackFrame: SessionRectSnapshot?,
        fallbackDisplaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?,
        isMirrored: Bool = false
    ) -> CGRect? {
        sessionWindowFrameResolver.resolvedStartupPrimaryWindowFrame(
            primaryFrame: primarySnapshot?.frame?.cgRect,
            primaryDisplay: sessionSourceDisplaySnapshot(from: primarySnapshot?.display),
            fallbackFrame: fallbackFrame?.cgRect,
            fallbackDisplay: sessionSourceDisplaySnapshot(from: fallbackDisplaySnapshot),
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    nonisolated static func resolvedWindowFrame(
        from frameSnapshot: SessionRectSnapshot?,
        display displaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?
    ) -> CGRect? {
        sessionWindowFrameResolver.resolvedWindowFrame(
            from: frameSnapshot?.cgRect,
            display: sessionSourceDisplaySnapshot(from: displaySnapshot),
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        )
    }

    func displaySnapshot(for window: NSWindow?) -> SessionDisplaySnapshot? {
        guard let geometry = Self.displayGeometryReader.screenGeometry(for: window) else {
            return nil
        }
        return SessionDisplaySnapshot(
            displayID: geometry.displayID,
            stableID: geometry.stableID,
            frame: SessionRectSnapshot(geometry.frame),
            visibleFrame: SessionRectSnapshot(geometry.visibleFrame)
        )
    }

    private func startSessionAutosaveTimerIfNeeded() {
        sessionAutosaveScheduler.start()
    }

    // Internal (not private) so it witnesses the `ApplicationTerminationHost`
    // `stopSessionAutosaveTimer()` teardown requirement directly.
    func stopSessionAutosaveTimer() {
        sessionAutosaveScheduler.stop()
    }

    private func installLifecycleSnapshotObserversIfNeeded() {
        guard lifecycleSnapshotConsumeTask == nil else { return }
        sessionLifecycleObserver.installIfNeeded()
        lifecycleSnapshotConsumeTask = Task { @MainActor [weak self] in
            guard let observer = self?.sessionLifecycleObserver else { return }
            for await event in observer.events {
                guard let self else { return }
                self.handleSessionLifecycleEvent(event)
            }
        }
        registerDisplayReconfigurationCallbackIfNeeded()
        displayReconfigurationObserver = NotificationCenter.default.addObserver(
            forName: Self.displayReconfigurationNotification,
            object: self,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                let isBeginning = (notification.userInfo?["isBeginning"] as? Bool) ?? false
                self?.handleDisplayReconfiguration(isBeginning: isBeginning)
            }
        }
        screenChangeReconcileObserver = NotificationCenter.default.addObserver(
            forName: Self.screenChangeReconcileNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileMainWindowFramesAfterScreenChange()
            }
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
#if DEBUG
                let names = NSScreen.screens.map(\.localizedName).joined(separator: ", ")
                cmuxDebugLog(
                    "monitorMemory.screenChange displays=\(NSScreen.screens.count) [\(names)]"
                )
#endif
                self.handleScreenParametersDidChange()
            }
        }
    }

    /// Forwards one ``SessionLifecycleEvent`` to the app-coupled session-save /
    /// socket-restart body the legacy lifecycle observer closure ran, preserving
    /// the `isTerminatingApp` branch exactly.
    private func handleSessionLifecycleEvent(_ event: SessionLifecycleEvent) {
        switch event {
        case .willPowerOff:
            isTerminatingApp = true
            _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
            closedItemHistory.flushPendingSaves()
        case .sessionDidResignActive:
            if isTerminatingApp {
                _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
                closedItemHistory.flushPendingSaves()
            } else {
                saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
            }
        case .didWake:
            restartSocketListenerIfEnabled(source: "workspace.didWake")
        }
    }

    // Internal (not private) so the DEBUG `MultiWindowNotificationUITestScaffold`
    // can resolve the socket configuration it probes for the socket-sanity stage.
    // Forwards to `SocketListenerLifecycleCoordinator`, adapting its DTO back to
    // the tuple shape the remaining UI-test/menu callers read.
    func socketListenerConfigurationIfEnabled() -> (mode: SocketControlMode, path: String)? {
        guard let config = socketListenerLifecycle.configurationIfEnabled() else { return nil }
        return (mode: config.mode, path: config.path)
    }

    private func reserveInitialSocketPathIfNeeded() {
        socketListenerLifecycle.reserveInitialSocketPathIfNeeded()
    }

    private func startSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        socketListenerLifecycle.start(target: tabManager, source: source)
    }

    private func ensureSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        socketListenerLifecycle.ensure(target: tabManager, source: source)
    }

    // Internal (not private) so the DEBUG `MultiWindowNotificationUITestScaffold`
    // can restart the listener while it waits for the socket to come up.
    func restartSocketListenerIfEnabled(source: String) {
        socketListenerLifecycle.restart(source: source)
    }

    private func disableSuddenTerminationIfNeeded() {
        socketListenerLifecycle.disableSuddenTerminationIfNeeded()
    }

    // Internal (not private) so it witnesses the `ApplicationTerminationHost`
    // `enableSuddenTerminationIfNeeded()` teardown requirement directly.
    func enableSuddenTerminationIfNeeded() {
        socketListenerLifecycle.enableSuddenTerminationIfNeeded()
    }

    private func sessionAutosaveFingerprint(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    ) -> Int? {
        guard !includeScrollback else { return nil }

        let contexts = registeredMainWindows.sorted { lhs, rhs in
            lhs.windowId.uuidString < rhs.windowId.uuidString
        }

        // Flatten only the windows that survive the cap; the legacy body read
        // `contexts.count` for the count but only did per-window work for
        // `contexts.prefix(maxWindows)`.
        let cappedInputs = contexts.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
            .map { context -> SessionSnapshotFingerprintWindowInput in
                let fingerprintSidebarState = sidebarState(for: context)
                let sidebarSelectionTag: Int
                switch sidebarSelectionState(for: context).selection {
                case .tabs:
                    sidebarSelectionTag = 0
                case .notifications:
                    sidebarSelectionTag = 1
                }
                let window = context.window ?? windowForMainWindowId(context.windowId)
                let frame = window?.frame
                return SessionSnapshotFingerprintWindowInput(
                    windowId: context.windowId,
                    tabManagerFingerprint: context.tabManager.sessionAutosaveFingerprint(
                        restorableAgentIndex: restorableAgentIndex,
                        surfaceResumeBindingIndex: surfaceResumeBindingIndex
                    ),
                    sidebarIsVisible: fingerprintSidebarState.isVisible,
                    quantizedSidebarWidth: Int(
                        SessionPersistencePolicy.sanitizedSidebarWidth(Double(fingerprintSidebarState.persistedWidth)).rounded()
                    ),
                    sidebarSelectionTag: sidebarSelectionTag,
                    foldFrame: { hasher in
                        if let frame {
                            Self.sessionPersistenceDecisionPolicy.hashFrame(frame, into: &hasher)
                        } else {
                            hasher.combine(-1)
                        }
                    }
                )
            }

        return Self.sessionSnapshotBuilder.fingerprint(
            cappedInputs: cappedInputs,
            windowCount: contexts.count
        )
    }

    @discardableResult
    private func saveSessionSnapshot(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false,
        preserveManualRestoreBackupOnMissingPrimary: Bool = false,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> Bool {
        if Self.sessionPersistenceDecisionPolicy.shouldSkipSessionSaveDuringRestore(
            isApplyingSessionRestore: isApplyingSessionRestore,
            includeScrollback: includeScrollback
        ) {
#if DEBUG
            cmuxDebugLog("session.save.skipped reason=session_restore_in_progress includeScrollback=0")
#endif
            return false
        }
        let writeSynchronously = Self.sessionPersistenceDecisionPolicy.shouldWriteSessionSnapshotSynchronously(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: includeScrollback
        )
        if writeSynchronously {
            TextBoxInputTextView.flushPendingSessionDraftAttachmentCopies()
        }
#if DEBUG
        let timingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "session.saveSnapshot",
                startedAt: timingStart,
                extra: "includeScrollback=\(includeScrollback ? 1 : 0) removeWhenEmpty=\(removeWhenEmpty ? 1 : 0) sync=\(writeSynchronously ? 1 : 0)"
            )
        }
#endif

        let snapshotBuildResult = buildSessionSnapshotResult(
            includeScrollback: includeScrollback,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex
        )
        guard let snapshot = snapshotBuildResult.snapshot else {
            let preserveManualRestoreBackup =
                preserveManualRestoreBackupOnMissingPrimary ||
                snapshotBuildResult.removedCrashDiagnosticState
            persistSessionSnapshot(
                nil,
                removeWhenEmpty: removeWhenEmpty || snapshotBuildResult.removedCrashDiagnosticState,
                persistedGeometryData: nil,
                synchronously: writeSynchronously,
                preserveManualRestoreBackupOnMissingPrimary: preserveManualRestoreBackup
            )
            return false
        }

        let persistedGeometryData = snapshot.windows.first.flatMap { primaryWindow in
            Self.encodedPersistedWindowGeometryData(
                frame: primaryWindow.frame,
                display: primaryWindow.display
            )
        }

#if DEBUG
        debugLogSessionSaveSnapshot(snapshot, includeScrollback: includeScrollback)
#endif
        persistSessionSnapshot(
            snapshot,
            removeWhenEmpty: false,
            persistedGeometryData: persistedGeometryData,
            synchronously: writeSynchronously
        )
        return true
    }

#if DEBUG
    func debugBenchmarkSessionSnapshot(
        includeScrollback: Bool,
        persist: Bool
    ) -> [String: Any] {
        SessionSnapshotDebugBenchmark.run(
            includeScrollback: includeScrollback,
            persist: persist,
            buildSnapshot: { [self] includeScrollback in
                buildSessionSnapshot(includeScrollback: includeScrollback)
            },
            persistedGeometryData: { snapshot in
                snapshot?.windows.first.flatMap { primaryWindow in
                    Self.encodedPersistedWindowGeometryData(
                        frame: primaryWindow.frame,
                        display: primaryWindow.display
                    )
                }
            },
            persistSnapshot: { [self] snapshot, persistedGeometryData in
                persistSessionSnapshot(
                    snapshot,
                    removeWhenEmpty: false,
                    persistedGeometryData: persistedGeometryData,
                    synchronously: true
                )
            }
        )
    }

    func debugBuildSessionSnapshotForTesting(
        includeScrollback: Bool,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> AppSessionSnapshot? {
        buildSessionSnapshot(
            includeScrollback: includeScrollback,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex
        )
    }

    func debugSeedSessionSnapshotScrollback(charactersPerTerminal: Int) -> [String: Any] {
        let workspaces = sortedMainWindowContextsForSessionSnapshot().flatMap { context in
            context.tabManager.tabs.filter { !$0.isRemoteWorkspace }
        }
        return SessionSnapshotDebugBenchmark.seedScrollback(
            workspaces: workspaces,
            charactersPerTerminal: charactersPerTerminal
        )
    }
#endif

    /// Performs one scheduled session-snapshot autosave, called by
    /// ``SessionAutosaveScheduler`` after it has cleared the typing-quiet
    /// deferral and taken the in-flight latch. Lifted from the legacy
    /// `finishSessionAutosaveTick(source:generation:)`; the scheduler now owns
    /// the latch, the typing-quiet check, and the retry, so this body keeps only
    /// the app-coupled save: it allocates a process-detected scan generation,
    /// loads the resume indexes, guards against a stale scan, applies the
    /// unchanged-fingerprint skip, writes the snapshot, and records the new
    /// autosave state. `nonisolated(unsafe)`-free; runs on the main actor.
    func performScheduledAutosave(source: String) async {
        let generation = nextProcessDetectedSessionSaveGeneration()
#if DEBUG
        let timingStart = CmuxTypingTiming.start()
        let phaseStart = ProcessInfo.processInfo.systemUptime
        var fingerprintMs: Double = 0
        var saveMs: Double = 0
        defer {
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseStart) * 1000.0
            CmuxTypingTiming.logBreakdown(
                path: "session.autosaveTick.phase",
                totalMs: totalMs,
                thresholdMs: 2.0,
                parts: [
                    ("fingerprintMs", fingerprintMs),
                    ("saveMs", saveMs),
                ],
                extra: "source=\(source)"
            )
            CmuxTypingTiming.logDuration(
                path: "session.autosaveTick",
                startedAt: timingStart,
                extra: "source=\(source)"
            )
        }
#endif

        let now = Date()
#if DEBUG
        let fingerprintStart = ProcessInfo.processInfo.systemUptime
#endif
        let resumeIndexes = await ProcessDetectedResumeIndexes.load()
        guard !isTerminatingApp,
              isCurrentProcessDetectedSessionSaveGeneration(generation) else {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=stale_process_detected_scan includeScrollback=0 source=\(source)"
            )
#endif
            return
        }
        let autosaveFingerprint = sessionAutosaveFingerprint(
            includeScrollback: false,
            restorableAgentIndex: resumeIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
        )
#if DEBUG
        fingerprintMs = (ProcessInfo.processInfo.systemUptime - fingerprintStart) * 1000.0
#endif
        if Self.sessionPersistenceDecisionPolicy.shouldSkipSessionAutosaveForUnchangedFingerprint(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: false,
            previousFingerprint: lastSessionAutosaveFingerprint,
            currentFingerprint: autosaveFingerprint,
            lastPersistedAt: lastSessionAutosavePersistedAt,
            now: now
        ) {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=unchanged_autosave_fingerprint includeScrollback=0 source=\(source)"
            )
#endif
            return
        }

#if DEBUG
        let saveStart = ProcessInfo.processInfo.systemUptime
#endif
        _ = saveSessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: resumeIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
        )
#if DEBUG
        saveMs = (ProcessInfo.processInfo.systemUptime - saveStart) * 1000.0
#endif
        updateSessionAutosaveSaveState(
            includeScrollback: false,
            persistedAt: now,
            fingerprint: autosaveFingerprint
        )
    }

    // Internal (not private) so the `ApplicationTerminationHost` conformance in
    // `AppDelegate+ApplicationTerminationHost.swift` can witness it.
    @discardableResult
    func saveSessionSnapshotIncludingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false,
        preserveManualRestoreBackupOnMissingPrimary: Bool = false
    ) -> Bool {
        let resumeIndexes = ProcessDetectedResumeIndexes.loadSynchronously()
        return saveSessionSnapshot(
            includeScrollback: includeScrollback,
            removeWhenEmpty: removeWhenEmpty,
            preserveManualRestoreBackupOnMissingPrimary: preserveManualRestoreBackupOnMissingPrimary,
            restorableAgentIndex: resumeIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
        )
    }

    // Internal (not private) so the `ApplicationActivationHost` conformance in
    // `AppDelegate+ApplicationActivationHost.swift` can witness the resign-time
    // session snapshot.
    func saveSessionSnapshotAfterLoadingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false,
        preserveManualRestoreBackupOnMissingPrimary: Bool = false
    ) {
        let generation = nextProcessDetectedSessionSaveGeneration()
        Task { @MainActor [weak self] in
            let resumeIndexes = await ProcessDetectedResumeIndexes.load()
            guard let self,
                  !self.isTerminatingApp,
                  self.isCurrentProcessDetectedSessionSaveGeneration(generation) else { return }
            _ = self.saveSessionSnapshot(
                includeScrollback: includeScrollback,
                removeWhenEmpty: removeWhenEmpty,
                preserveManualRestoreBackupOnMissingPrimary: preserveManualRestoreBackupOnMissingPrimary,
                restorableAgentIndex: resumeIndexes.restorableAgentIndex,
                surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
            )
        }
    }

    @discardableResult
    private func nextProcessDetectedSessionSaveGeneration() -> UInt64 {
        processDetectedSessionSaveGeneration &+= 1
        return processDetectedSessionSaveGeneration
    }

    private func isCurrentProcessDetectedSessionSaveGeneration(_ generation: UInt64) -> Bool {
        generation == processDetectedSessionSaveGeneration
    }

    fileprivate func recordTypingActivity() {
        sessionAutosaveScheduler.recordTypingActivity()
    }

    private func updateSessionAutosaveSaveState(
        includeScrollback: Bool,
        persistedAt: Date,
        fingerprint: Int?
    ) {
        guard !isTerminatingApp, !includeScrollback else { return }
        lastSessionAutosaveFingerprint = fingerprint
        lastSessionAutosavePersistedAt = persistedAt
    }

    private func persistSessionSnapshot(
        _ snapshot: AppSessionSnapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool,
        preserveManualRestoreBackupOnMissingPrimary: Bool = false
    ) {
        sessionSnapshotPersistor.persist(
            snapshot,
            removeWhenEmpty: removeWhenEmpty,
            persistedGeometryData: persistedGeometryData,
            synchronously: synchronously,
            preserveManualRestoreBackupOnMissingPrimary: preserveManualRestoreBackupOnMissingPrimary
        )
    }

    func sortedMainWindowContextsForSessionSnapshot() -> [RegisteredMainWindow] {
        registeredMainWindows.sorted { lhs, rhs in
            let lhsWindow = lhs.window ?? windowForMainWindowId(lhs.windowId)
            let rhsWindow = rhs.window ?? windowForMainWindowId(rhs.windowId)
            let lhsIsKey = lhsWindow?.isKeyWindow ?? false
            let rhsIsKey = rhsWindow?.isKeyWindow ?? false
            if lhsIsKey != rhsIsKey {
                return lhsIsKey && !rhsIsKey
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func buildSessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex suppliedRestorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex suppliedSurfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> AppSessionSnapshot? {
        buildSessionSnapshotResult(
            includeScrollback: includeScrollback,
            restorableAgentIndex: suppliedRestorableAgentIndex,
            surfaceResumeBindingIndex: suppliedSurfaceResumeBindingIndex
        ).snapshot
    }

    private func buildSessionSnapshotResult(
        includeScrollback: Bool,
        restorableAgentIndex suppliedRestorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex suppliedSurfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> (snapshot: AppSessionSnapshot?, removedCrashDiagnosticState: Bool) {
        let contexts = sortedMainWindowContextsForSessionSnapshot()

        guard !contexts.isEmpty else { return (nil, false) }
        let restorableAgentIndex = suppliedRestorableAgentIndex ?? RestorableAgentSessionIndex.load()

        // `lazy` so per-window snapshots beyond the window cap are not built,
        // matching the legacy `contexts.lazy.compactMap { ... }.prefix(...)`.
        let createdAt = Date().timeIntervalSince1970
        let inputs = contexts.lazy.map { context -> SessionSnapshotWindowInput<SessionWindowSnapshot> in
            let snapshot = self.sessionWindowSnapshot(
                for: context,
                includeScrollback: includeScrollback,
                restorableAgentIndex: restorableAgentIndex,
                surfaceResumeBindingIndex: suppliedSurfaceResumeBindingIndex
            )
            // A dedicated remote-tmux mirror window needs a live SSH control
            // connection and should not restore as an empty shell. If the user
            // dragged local workspaces into that window, keep those local
            // workspaces: TabManager already prunes remote mirror workspaces
            // from its snapshot.
            let dropsWhenEmptyDedicatedRemoteWindow =
                self.remoteTmuxController.isDedicatedRemoteWindow(context.windowId)
                    && snapshot.tabManager.workspaces.isEmpty
            if dropsWhenEmptyDedicatedRemoteWindow {
                return SessionSnapshotWindowInput(
                    snapshot: snapshot,
                    dropsWhenEmptyDedicatedRemoteWindow: true
                )
            }

            let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(
                from: AppSessionSnapshot(
                    version: AppSessionSnapshot.currentSchemaVersion,
                    createdAt: createdAt,
                    windows: [snapshot]
                )
            )
            let prunedWindow = pruned.snapshot?.windows.first
            return SessionSnapshotWindowInput(
                snapshot: prunedWindow ?? snapshot,
                dropsWhenEmptyDedicatedRemoteWindow: false,
                dropsWhenCrashDiagnosticWindowRemoved: pruned.removedAny && prunedWindow == nil,
                removedCrashDiagnosticState: pruned.removedAny
            )
        }

        let buildResult = Self.sessionSnapshotBuilder.assembleWindowSnapshotResult(
            from: inputs,
            maxWindows: SessionPersistencePolicy.maxWindowsPerSnapshot
        )

        guard !buildResult.windows.isEmpty else {
            return (nil, buildResult.removedCrashDiagnosticState)
        }
        return (AppSessionSnapshot(
            version: AppSessionSnapshot.currentSchemaVersion,
            createdAt: createdAt,
            windows: buildResult.windows
        ), buildResult.removedCrashDiagnosticState)
    }

    private func sessionWindowSnapshot(
        for context: RegisteredMainWindow,
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> SessionWindowSnapshot {
        let tabManagerSnapshot = context.tabManager.sessionSnapshot(
            includeScrollback: includeScrollback,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex
        )

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            captureWindowConfigFrame(window, reason: "sessionSnapshot")
        }
        let snapshotSidebarState = sidebarState(for: context)
        return SessionWindowSnapshot(
            windowId: context.windowId,
            frame: window.map { SessionRectSnapshot($0.frame) },
            display: displaySnapshot(for: window),
            tabManager: tabManagerSnapshot,
            sidebar: SessionSidebarSnapshot(
                isVisible: snapshotSidebarState.isVisible,
                selection: SessionSidebarSelection(selection: sidebarSelectionState(for: context).selection),
                width: SessionPersistencePolicy.sanitizedSidebarWidth(Double(snapshotSidebarState.persistedWidth))
            ),
            configFrames: windowConfigFrames[context.windowId]?.entries
        )
    }

#if DEBUG
    private func debugLogSessionSaveSnapshot(
        _ snapshot: AppSessionSnapshot,
        includeScrollback: Bool
    ) {
        cmuxDebugLog(
            "session.save includeScrollback=\(includeScrollback ? 1 : 0) " +
                "windows=\(snapshot.windows.count)"
        )
        for (index, windowSnapshot) in snapshot.windows.enumerated() {
            let workspaceCount = windowSnapshot.tabManager.workspaces.count
            let selectedWorkspace = windowSnapshot.tabManager.selectedWorkspaceIndex.map(String.init) ?? "nil"
            cmuxDebugLog(
                "session.save.window idx=\(index) " +
                    "frame={\(sessionRectLogDescription(windowSnapshot.frame))} " +
                    "display={\(sessionDisplayLogDescription(windowSnapshot.display))} " +
                    "workspaces=\(workspaceCount) selected=\(selectedWorkspace)"
            )
        }
    }
#endif

    func notifyMainWindowContextsDidChange() {
        NotificationCenter.default.post(name: .mainWindowContextsDidChange, object: self)
    }

    func ensureMobileWorkspaceListObserver(for tabManager: TabManager) {
        let id = ObjectIdentifier(tabManager)
        if mobileWorkspaceListObservers[id] == nil {
            mobileWorkspaceListObservers[id] = MobileWorkspaceListObserver(tabManager: tabManager, notificationStore: notificationStore)
        }
    }

    private func removeMobileWorkspaceListObserverIfUnused(for tabManager: TabManager) {
        guard registeredMainWindow(forManager: tabManager) == nil else {
            return
        }
        mobileWorkspaceListObservers.removeValue(forKey: ObjectIdentifier(tabManager))
    }

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active. Thin forwarder: the
    /// window-identity decision + god-effect sequencing lives in
    /// ``WindowLifecycleCoordinator/registerMainWindow(_:windowId:tabManager:slices:)``;
    /// the app-typed per-window slices ride across the seam in a
    /// ``MainWindowRegistrationSlices`` value, and every god-type effect is a
    /// ``WindowLifecycleHosting`` callback implemented in
    /// `AppDelegate+WindowLifecycleRegistrationHosting.swift`.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        fileExplorerState: FileExplorerState? = nil,
        cmuxConfigStore: CmuxConfigStore? = nil
    ) {
        windowLifecycle.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            slices: MainWindowRegistrationSlices(
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                fileExplorerState: fileExplorerState,
                cmuxConfigStore: cmuxConfigStore
            )
        )
    }

#if DEBUG
    /// Thin forwarder to
    /// ``WindowLifecycleCoordinator/registerMainWindowContextForTesting(windowId:tabManager:slices:)``;
    /// the window-less slice seeding runs in the
    /// ``WindowLifecycleHosting/seedTestingMainWindowSlices(windowId:testId:tabManager:slices:)``
    /// callback. The fresh `SidebarState()`/`SidebarSelectionState()` the old test
    /// scaffold built inline now ride across the seam in the slices value.
    @discardableResult
    func registerMainWindowContextForTesting(
        windowId: UUID = UUID(),
        tabManager: TabManager,
        cmuxConfigStore: CmuxConfigStore? = nil,
        fileExplorerState: FileExplorerState? = nil
    ) -> UUID {
        windowLifecycle.registerMainWindowContextForTesting(
            windowId: windowId,
            tabManager: tabManager,
            slices: MainWindowRegistrationSlices(
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: fileExplorerState,
                cmuxConfigStore: cmuxConfigStore
            )
        )
    }

    func sessionSnapshotForTesting(includeScrollback: Bool = false) -> AppSessionSnapshot? {
        buildSessionSnapshot(includeScrollback: includeScrollback)
    }

#endif

    /// Lifted to ``CmuxWindowing/MainWindowSummary``; aliased so existing
    /// `AppDelegate.MainWindowSummary` references stay source-identical.
    typealias MainWindowSummary = CmuxWindowing.MainWindowSummary

    /// Lifted to ``CmuxWorkspaces/WorkspaceCommandWindowTarget``; aliased so
    /// existing `AppDelegate.WindowMoveTarget` references stay source-identical.
    /// The package value type drops the legacy `tabManager` handle (no consumer
    /// read it; window membership is still gated by `tabManagerFor(windowId:)`
    /// below, the manager value was simply never surfaced).
    typealias WindowMoveTarget = CmuxWorkspaces.WorkspaceCommandWindowTarget

    /// Lifted to ``CmuxWorkspaces/WorkspaceMoveTarget``; aliased so existing
    /// `AppDelegate.WorkspaceMoveTarget` references stay source-identical. The
    /// package value type drops the legacy `tabManager` handle (no consumer read
    /// it; the move shim re-resolves the manager by `workspaceId`).
    typealias WorkspaceMoveTarget = CmuxWorkspaces.WorkspaceMoveTarget

    func windowMoveTargets(referenceWindowId: UUID?) -> [WindowMoveTarget] {
        environment.mainWindowRouter.windowMoveTargets(referenceWindowId: referenceWindowId)
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [WorkspaceMoveTarget] {
        environment.mainWindowRouter.workspaceMoveTargets(
            excludingWorkspaceId: excludingWorkspaceId,
            referenceWindowId: referenceWindowId
        )
    }

    @discardableResult
    func moveWorkspaceToWindow(workspaceId: UUID, windowId: UUID, atIndex: Int? = nil, focus: Bool = true) -> Bool {
        environment.mainWindowRouter.moveWorkspaceToWindow(
            workspaceId: workspaceId,
            windowId: windowId,
            atIndex: atIndex,
            focus: focus
        )
    }

    @discardableResult
    func moveWorkspaceToNewWindow(workspaceId: UUID, focus: Bool = true) -> UUID? {
        environment.mainWindowRouter.moveWorkspaceToNewWindow(workspaceId: workspaceId, focus: focus)
    }

    func locateBonsplitSurface(tabId: UUID) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        windowRegistry.locateBonsplitSurface(tabId: tabId)
    }

    /// Moves the surface `panelId` into `targetWorkspaceId` at the resolved
    /// destination, returning whether the move succeeded. The move decision now
    /// lives in ``PaneSurfaceMoveCoordinator`` (CmuxWorkspaces); this thin
    /// entrypoint builds the typed ``PaneSurfaceMoveRequest`` and forwards through
    /// the ``PaneLayoutControlling`` seam, which drives the irreducible live
    /// mutations back through ``PaneSurfaceMoveHosting`` (this `AppDelegate`).
    @discardableResult
    func moveSurface(
        panelId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
        paneSurfaceMove.move(surface: PaneSurfaceMoveRequest(
            panelId: panelId,
            targetWorkspaceId: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget.map {
                PaneSurfaceMoveRequest.SplitTarget(orientation: $0.orientation, insertFirst: $0.insertFirst)
            },
            focus: focus,
            focusWindow: focusWindow
        ))
    }

    /// Moves the existing bonsplit tab `tabId` into `targetWorkspaceId`, returning
    /// whether the move succeeded. Forwards through ``PaneLayoutControlling``; the
    /// coordinator resolves the tab to its panel id (via ``PaneSurfaceMoveHosting``)
    /// then runs the same move decision as ``moveSurface(panelId:toWorkspace:...)``.
    @discardableResult
    func moveBonsplitTab(
        tabId: UUID,
        toWorkspace targetWorkspaceId: UUID,
        targetPane: PaneID? = nil,
        targetIndex: Int? = nil,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)? = nil,
        focus: Bool = true,
        focusWindow: Bool = true
    ) -> Bool {
        paneSurfaceMove.moveBonsplitTab(
            tabId: tabId,
            toWorkspace: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget.map {
                PaneSurfaceMoveRequest.SplitTarget(orientation: $0.orientation, insertFirst: $0.insertFirst)
            },
            focus: focus,
            focusWindow: focusWindow
        )
    }

    @discardableResult
    func focusScriptableMainWindow(windowId: UUID, bringToFront shouldBringToFront: Bool) -> Bool {
        environment.mainWindowRouter.focusScriptableWindow(
            windowId: windowId,
            bringToFront: shouldBringToFront
        )
    }

    @discardableResult
    func addWorkspace(windowId: UUID, workingDirectory: String? = nil, bringToFront shouldBringToFront: Bool = false) -> UUID? {
        guard let state = scriptableMainWindow(windowId: windowId) else { return nil }
        if shouldBringToFront, let window = state.window {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = state.tabManager.addWorkspace(
            workingDirectory: workingDirectory,
            select: shouldBringToFront
        )
        return workspace.id
    }

    private func markCommandPaletteOpenRequested(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePresentation.markOpenRequested(windowId)
    }

    private func postCommandPaletteRequest(
        kind: CommandPaletteRequestKind,
        preferredWindow: NSWindow?,
        source: String
    ) {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let windowId = targetWindow.flatMap { mainWindowId(for: $0) }
        commandPalettePresentation.postRequest(
            kind: kind,
            windowId: windowId,
            source: source,
            debugTarget: debugWindowToken(targetWindow),
            clearBrowserFocusMode: {
                if let targetWindow,
                   let context = contextForMainWindow(targetWindow) {
                    _ = context.tabManager.setFocusedBrowserFocusModeActive(
                        false,
                        reason: "commandPaletteRequest.\(source)"
                    )
                }
            },
            post: {
                NotificationCenter.default.post(
                    name: Notification.Name(kind.notificationName),
                    object: targetWindow
                )
            }
        )
    }

    func requestCommandPaletteCommands(preferredWindow: NSWindow? = nil, source: String = "api.commandPalette") {
        postCommandPaletteRequest(
            kind: .commands,
            preferredWindow: preferredWindow,
            source: source
        )
    }

    func requestCommandPaletteSwitcher(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteSwitcher") {
        postCommandPaletteRequest(
            kind: .switcher,
            preferredWindow: preferredWindow,
            source: source
        )
    }

    func requestCommandPaletteRenameTab(preferredWindow: NSWindow? = nil, source: String = "api.commandPaletteRenameTab") {
        postCommandPaletteRequest(
            kind: .renameTab,
            preferredWindow: preferredWindow,
            source: source
        )
    }

    func requestCommandPaletteRenameWorkspace(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteRenameWorkspace"
    ) {
        postCommandPaletteRequest(
            kind: .renameWorkspace,
            preferredWindow: preferredWindow,
            source: source
        )
    }

    func requestCommandPaletteEditWorkspaceDescription(
        preferredWindow: NSWindow? = nil,
        source: String = "api.commandPaletteEditWorkspaceDescription"
    ) {
        postCommandPaletteRequest(
            kind: .editWorkspaceDescription,
            preferredWindow: preferredWindow,
            source: source
        )
    }

    private func clearCommandPalettePendingOpen(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePresentation.clearPendingOpen(windowId)
    }

    private func pruneExpiredCommandPalettePendingOpenStates() {
        commandPalettePresentation.pruneExpiredPendingOpenStates()
    }

    private func isCommandPalettePendingOpen(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return commandPalettePresentation.isPendingOpen(windowId)
    }

    private func beginCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePresentation.beginEscapeSuppression(windowId)
    }

    private func endCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPalettePresentation.endEscapeSuppression(windowId)
    }

    private func shouldConsumeSuppressedEscape(event: NSEvent, window: NSWindow?) -> Bool {
        guard let window,
              let windowId = mainWindowId(for: window) else {
            return false
        }
        return commandPalettePresentation.shouldConsumeSuppressedEscape(windowId)
    }

    private func recentCommandPaletteRequestAge(for window: NSWindow?) -> TimeInterval? {
        guard let window,
              let windowId = mainWindowId(for: window) else {
            return nil
        }
        return commandPalettePresentation.recentRequestAge(windowId)
    }

    private func escapeSuppressionWindow(for event: NSEvent) -> NSWindow? {
        commandPaletteWindowForShortcutEvent(event) ?? event.window ?? shortcutRoutingActiveWindow
    }

    @discardableResult
    private func clearEscapeSuppressionForKeyUp(event: NSEvent, consumeIfSuppressed: Bool = false) -> Bool {
        guard event.type == .keyUp, event.keyCode == 53 else { return false }
        let suppressionWindow = escapeSuppressionWindow(for: event)
        let didConsume = consumeIfSuppressed && shouldConsumeSuppressedEscape(event: event, window: suppressionWindow)
        if let window = suppressionWindow {
            endCommandPaletteEscapeSuppression(for: window)
#if DEBUG
            cmuxDebugLog(
                "shortcut.escape suppressionClear target={\(debugWindowToken(window))} " +
                "keyUpConsumed=\(didConsume ? 1 : 0)"
            )
#endif
            return didConsume
        }
        commandPalettePresentation.clearAllEscapeSuppression()
#if DEBUG
        cmuxDebugLog("shortcut.escape suppressionClear target={nil} clearedAll=1 keyUpConsumed=\(didConsume ? 1 : 0)")
#endif
        return didConsume
    }

    func setCommandPaletteVisible(_ visible: Bool, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPalettePresentation.setVisible(
            visible,
            for: windowId,
            debugWindow: debugWindowToken(window),
            clearBrowserFocusMode: {
                if let context = contextForMainWindow(window) {
                    _ = context.tabManager.setFocusedBrowserFocusModeActive(false, reason: "commandPaletteVisible")
                }
            },
            postVisibilityDidChange: { visible in
                NotificationCenter.default.post(
                    name: .commandPaletteVisibilityDidChange,
                    object: window,
                    userInfo: [
                        "windowId": windowId,
                        "visible": visible,
                    ]
                )
            }
        )
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        commandPalettePresentation.isVisible(windowId)
    }

    func setCommandPaletteSelectionIndex(_ index: Int, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPalettePresentation.setSelectionIndex(index, for: windowId)
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        commandPalettePresentation.selectionIndex(windowId)
    }

    func setCommandPaletteSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPalettePresentation.setSnapshot(snapshot, for: windowId)
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        commandPalettePresentation.snapshot(windowId)
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return commandPalettePresentation.isVisible(windowId)
    }

    func isCommandPaletteEffectivelyVisible(for window: NSWindow) -> Bool {
        isCommandPaletteEffectivelyVisible(in: window)
    }

    func shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
        window: NSWindow,
        responder: NSResponder?
    ) -> Bool {
        guard isCommandPaletteVisible(for: window) else { return false }
        guard let responder else { return false }
        guard !isCommandPaletteResponder(responder) else { return false }
        return isFocusStealingResponderWhileCommandPaletteVisible(responder)
    }

    private func isCommandPaletteResponder(_ responder: NSResponder) -> Bool {
        if let textView = responder as? NSTextView, textView.isFieldEditor {
            if let delegateView = textView.delegate as? NSView {
                return delegateView.isInsideCommandPaletteOverlay
            }
            // SwiftUI can attach a non-view delegate to TextField editors.
            // When command palette is visible, its search/rename editor is the
            // only expected field editor inside the main window.
            return true
        }
        if let view = responder as? NSView {
            return view.isInsideCommandPaletteOverlay
        }
        return false
    }

    private func isFocusStealingResponderWhileCommandPaletteVisible(_ responder: NSResponder) -> Bool {
        responder.isCommandPaletteFocusStealingTerminalOrBrowser
    }

    private func keyRoutingOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }
        if let editor = responder as? NSTextView,
           editor.isFieldEditor {
            return cmuxFieldEditorOwnerView(editor) ?? editor
        }
        return responder as? NSView
    }

    private func responderHasViableKeyRoutingOwner(
        _ responder: NSResponder,
        in window: NSWindow
    ) -> Bool {
        if let ghosttyView = cmuxOwningGhosttyView(for: responder) {
            if ghosttyView.window !== window {
                return false
            }
            if ghosttyView.isHiddenOrHasHiddenAncestor {
                return false
            }
            return ghosttyView === window.contentView || ghosttyView.superview != nil
        }

        guard let ownerView = keyRoutingOwnerView(for: responder) else {
            return false
        }

        if ownerView.window !== window {
            return false
        }

        if ownerView.isHiddenOrHasHiddenAncestor {
            return false
        }

        if ownerView !== window.contentView, ownerView.superview == nil {
            return false
        }

        return true
    }

    private func responderNeedsFocusedTerminalKeyRepair(
        _ responder: NSResponder?,
        in window: NSWindow,
        hostedView: GhosttySurfaceScrollView
    ) -> Bool {
        guard let responder else { return true }
        if isRightSidebarFocusResponder(responder, in: window) {
            return false
        }
        return focusedTerminalKeyRepairNeeded(
            responderIsWindow: responder is NSWindow,
            responderHasViableKeyRoutingOwner: responderHasViableKeyRoutingOwner(responder, in: window),
            responderMatchesPreferredKeyboardFocus: hostedView.responderMatchesPreferredKeyboardFocus(responder)
        )
    }

    func repairFocusedTerminalKeyboardRoutingIfNeeded(
        window: NSWindow,
        event: NSEvent,
        firstResponderOverride: NSResponder?
    ) {
        guard event.type == .keyDown else { return }
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isMainTerminalWindow(window) else { return }
        guard window.attachedSheet == nil else { return }
        guard !isCommandPaletteEffectivelyVisible(in: window) else { return }
        let firstResponder = firstResponderOverride ?? window.firstResponder
        // If the active first responder is owned by a non-terminal interaction surface,
        // never re-route the keystroke to the terminal. Symmetric with
        // applyFirstResponderIfNeeded's foreign focus guard.
        if let firstResponder,
           shouldRespectForeignFirstResponder(firstResponder, in: window, isRightSidebarOwner: {
               isRightSidebarFocusResponder($0, in: window)
           }) {
            return
        }
        guard let context = contextForMainWindow(window) ?? contextForMainTerminalWindow(window),
              let workspace = context.tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: panelId) else {
            return
        }
        if normalizedFlags.contains(.command) {
            let responderHasViableOwner = firstResponder.map { responderHasViableKeyRoutingOwner($0, in: window) } ?? false
            let commandEquivalentNeedsRepair = shouldRepairFocusedTerminalCommandEquivalentInputs(
                flags: normalizedFlags,
                responderIsWindow: firstResponder is NSWindow,
                responderHasViableKeyRoutingOwner: responderHasViableOwner
            )
            guard commandEquivalentNeedsRepair else { return }
        } else {
            guard responderNeedsFocusedTerminalKeyRepair(
                firstResponder,
                in: window,
                hostedView: terminalPanel.hostedView
            ) else { return }
        }

#if DEBUG
        let before = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let target = terminalPanel.hostedView.preferredPanelFocusIntentForActivation()
        let targetLabel: String = {
            switch target {
            case .surface:
                return "surface"
            case .findField:
                return "searchField"
            case .textBoxInput:
                return "textBoxInput"
            }
        }()
        let mode = normalizedFlags.contains(.command) ? "command" : "plain"
        cmuxDebugLog(
            "focus.keyRepair attempt window=\(ObjectIdentifier(window)) " +
            "workspace=\(String(workspace.id.uuidString.prefix(5))) " +
            "panel=\(String(panelId.uuidString.prefix(5))) " +
            "mode=\(mode) " +
            "target=\(targetLabel) " +
            "fr=\(before) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue)"
        )
        debugFocusedTerminalKeyRepairObserverForTesting?(window, event, firstResponder)
#endif

        terminalPanel.hostedView.ensureFocus(for: workspace.id, surfaceId: panelId)

#if DEBUG
        let after = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "focus.keyRepair result window=\(ObjectIdentifier(window)) " +
            "panel=\(String(panelId.uuidString.prefix(5))) " +
            "isSurfaceResponder=\(terminalPanel.hostedView.isSurfaceViewFirstResponder() ? 1 : 0) " +
            "fr=\(after)"
        )
#endif
    }

    /// Resolve the workspace that currently owns a panel/surface ID.
    /// Prefer the provided workspace when available, then fall back to global lookup.
    func workspaceContainingPanel(
        panelId: UUID,
        preferredWorkspaceId: UUID? = nil
    ) -> (workspace: Workspace, tabManager: TabManager)? {
        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId),
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil,
           workspace.surfaceIdFromPanelId(panelId) != nil {
            return (workspace, manager)
        }

        if let located = windowRegistry.locateSurface(surfaceId: panelId),
           let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
           workspace.panels[panelId] != nil,
           workspace.surfaceIdFromPanelId(panelId) != nil {
            return (workspace, located.tabManager)
        }

        if let preferredWorkspaceId,
           let manager = tabManagerFor(tabId: preferredWorkspaceId) ?? tabManager,
           let workspace = manager.tabs.first(where: { $0.id == preferredWorkspaceId }),
           workspace.panels[panelId] != nil,
           workspace.surfaceIdFromPanelId(panelId) != nil {
            return (workspace, manager)
        }

        if let manager = tabManager,
           let workspace = manager.tabs.first(where: {
               $0.panels[panelId] != nil && $0.surfaceIdFromPanelId(panelId) != nil
           }) {
            return (workspace, manager)
        }

        return nil
    }

    func locateGhosttySurface(_ surface: ghostty_surface_t?) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        guard let surface else { return nil }
        for ctx in registeredMainWindows {
            for ws in ctx.tabManager.tabs {
                for (panelId, panel) in ws.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    if terminal.surface.surface == surface {
                        return (ctx.windowId, ws.id, panelId, ctx.tabManager)
                    }
                }
            }
        }
        for route in recoverableMainWindowRoutes() {
            guard let manager = route.tabManager else { continue }
            for ws in manager.tabs {
                for (panelId, panel) in ws.panels {
                    guard let terminal = panel as? TerminalPanel else { continue }
                    if terminal.surface.surface == surface {
                        return (route.windowId, ws.id, panelId, manager)
                    }
                }
            }
        }
        return nil
    }

    func refreshTerminalSurfacesAfterGhosttyConfigReload(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    ) {
        var refreshedCount = 0
        forEachTerminalPanel { terminalPanel in
            let liveSurface = terminalPanel.surface.liveSurfaceForGhosttyAccess(
                reason: "appDelegate.refreshAfterGhosttyConfigReload"
            )
            GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
                to: liveSurface,
                source: source,
                reloadSurfaceConfiguration: { surface, soft, source in
                    GhosttyApp.shared.reloadSurfaceConfiguration(
                        surface,
                        soft: soft,
                        source: source,
                        preferredColorScheme: preferredColorScheme
                    )
                },
                applySurfaceColorScheme: {
                    terminalPanel.hostedView.reapplySurfaceColorSchemeAfterGhosttyConfigReload(
                        preferredColorScheme: preferredColorScheme
                    )
                },
                refreshHostBackground: {
                    terminalPanel.hostedView.refreshHostBackgroundAfterGhosttyConfigReload()
                },
                forceRefresh: { reason in
                    terminalPanel.surface.forceRefresh(reason: reason)
                }
            )
            refreshedCount += 1
        }
#if DEBUG
        cmuxDebugLog("reload.config.surfaceRefresh source=\(source) count=\(refreshedCount)")
#endif
    }

    private func forEachTerminalPanel(_ body: (TerminalPanel) -> Void) {
        var seenManagers: Set<ObjectIdentifier> = []

        func visitManager(_ manager: TabManager?) {
            guard let manager else { return }
            let managerId = ObjectIdentifier(manager)
            guard seenManagers.insert(managerId).inserted else { return }
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let terminalPanel = panel as? TerminalPanel else { continue }
                    body(terminalPanel)
                }
            }
        }

        visitManager(tabManager)
        for context in registeredMainWindows {
            visitManager(context.tabManager)
        }
    }

    /// Focuses the main window for `windowId`. Forwards to ``windowLifecycle``;
    /// the window resolve, visibility-controller focus, and lifecycle publish
    /// stay app-side witnesses behind the seam.
    func focusMainWindow(windowId: UUID) -> Bool {
        windowLifecycle.focusMainWindow(windowId: windowId)
    }

    /// Discards the main window for `windowId` without recording closed-window
    /// history. Forwards to ``windowLifecycle``; the `close` stays an app-side
    /// witness.
    func discardMainWindowWithoutClosedHistory(windowId: UUID) {
        windowLifecycle.discardMainWindowWithoutClosedHistory(windowId: windowId)
    }

    /// Presents the close-window confirmation alert for `window` and returns the
    /// user's decision. The ``WindowLifecycleHosting`` witness for the app-side
    /// `NSAlert` plus its localized strings (and the DEBUG confirmation hook).
    func confirmCloseMainWindow(_ window: NSWindow) -> Bool {
#if DEBUG
        if let debugCloseMainWindowConfirmationHandler {
            return debugCloseMainWindowConfirmationHandler(window)
        }
#endif

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "dialog.closeWindow.title", defaultValue: "Close window?")
        alert.informativeText = String(
            localized: "dialog.closeWindow.message",
            defaultValue: "This will close the current window and all of its workspaces."
        )
        alert.addButton(withTitle: String(localized: "common.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        if let closeButton = alert.buttons.first {
            alertWindow.defaultButtonCell = closeButton.cell as? NSButtonCell
            alertWindow.initialFirstResponder = closeButton
            DispatchQueue.main.async {
                _ = alertWindow.makeFirstResponder(closeButton)
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Closes `window` with a confirmation prompt for main terminal windows.
    /// Forwards to ``windowLifecycle``; the confirmation alert and the close stay
    /// app-side witnesses.
    @discardableResult
    func closeWindowWithConfirmation(_ window: NSWindow) -> Bool {
        windowLifecycle.closeWindowWithConfirmation(window)
    }

    func rollbackDetachedSurface(
        _ detached: Workspace.DetachedSurfaceTransfer,
        to workspace: Workspace,
        sourcePane: PaneID?,
        sourceIndex: Int?,
        focus: Bool
    ) {
        environment.mainWindowRouter.rollbackDetachedSurface(
            detached,
            to: workspace,
            sourcePane: sourcePane,
            sourceIndex: sourceIndex,
            focus: focus
        )
    }

    func reassertCrossWindowSurfaceMoveFocusIfNeeded(
        destinationWindowId: UUID,
        sourceWindowId: UUID,
        destinationWorkspaceId: UUID,
        destinationPanelId: UUID,
        destinationManager: TabManager
    ) {
        let reassert: @MainActor @Sendable () -> Void = { [weak self, weak destinationManager] in
            guard let self, let destinationManager else { return }
            guard let workspace = destinationManager.tabs.first(where: { $0.id == destinationWorkspaceId }),
                  workspace.panels[destinationPanelId] != nil else {
                return
            }
            guard let destinationWindow = self.mainWindow(for: destinationWindowId) else { return }
            guard let keyWindow = NSApp.keyWindow,
                  let keyWindowId = self.mainWindowId(for: keyWindow),
                  keyWindowId == sourceWindowId,
                  keyWindow !== destinationWindow else {
                return
            }

            self.bringToFront(destinationWindow)
            destinationManager.focusTab(
                destinationWorkspaceId,
                surfaceId: destinationPanelId,
                suppressFlash: true
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { reassert() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { MainActor.assumeIsolated { reassert() } }
    }

    /// The live window for `context`. Forwards to ``windowLifecycle``, which
    /// funnels the `context.window ?? windowForMainWindowId(context.windowId)`
    /// read through the ``WindowLifecycleHosting`` leaf accessors.
    func resolvedWindow(for context: RegisteredMainWindow) -> NSWindow? {
        windowLifecycle.resolvedWindow(for: context)
    }

    /// The window id encoded in `window`'s `cmux.main.<uuid>` identifier (pure
    /// parse). Forwards to ``windowLifecycle``.
    func mainWindowId(from window: NSWindow) -> UUID? {
        windowLifecycle.mainWindowId(from: window)
    }

    /// The resolved registered window for the main terminal `window`. Forwards to
    /// ``windowLifecycle``, which owns window↔id identity and the
    /// identifier/window-number fallbacks; the `isMainTerminalWindow` gate stays
    /// the app-side witness below.
    func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> RegisteredMainWindow? {
        windowLifecycle.contextForMainTerminalWindow(window, reindex: reindex)
    }

    /// Discards an orphaned registered `context`. Forwards to ``windowLifecycle``;
    /// relaxed from `private` to `internal` so the `WorkspaceCreationActionHosting`
    /// witnesses in AppDelegate+WorkspaceCreationActionHosting.swift can reach it.
    func discardOrphanedMainWindowContext(_ context: RegisteredMainWindow, allowWindowlessFallback: Bool = false) {
        windowLifecycle.discardOrphanedMainWindowContext(context, allowWindowlessFallback: allowWindowlessFallback)
    }

    /// Discards every windowless orphan context. Forwards to ``windowLifecycle``.
    private func pruneWindowlessMainWindowContexts() {
        windowLifecycle.pruneWindowlessMainWindowContexts()
    }

#if DEBUG
    func unregisterMainWindowContextForTesting(windowId: UUID) {
        windowLifecycle.unregisterMainWindowContextForTesting(windowId: windowId)
    }
#endif

    /// The window id for `window`, preferring live identity then the identifier
    /// parse. Forwards to ``windowLifecycle``.
    private func mainWindowId(for window: NSWindow) -> UUID? {
        windowLifecycle.mainWindowId(for: window)
    }

    private func isCommandPaletteResponderActive(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           !(textView.delegate is NSView) {
            // Field-editor delegates can be non-view responders. Confirm the overlay is
            // mounted and visible to avoid treating unrelated editors as palette input.
            return window.isCommandPaletteOverlayPresented
        }
        return isCommandPaletteResponder(responder)
    }

    private func isCommandPaletteMultilineTextResponderActive(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView,
              !textView.isFieldEditor else {
            return false
        }
        return isCommandPaletteResponder(textView)
    }

    private func commandPaletteMarkedTextInput(in window: NSWindow) -> NSTextView? {
        if let textView = window.firstResponder as? NSTextView,
           isCommandPaletteResponder(textView),
           textView.hasMarkedText() {
            return textView
        }

        if let textField = window.firstResponder as? NSTextField,
           let editor = textField.currentEditor() as? NSTextView,
           isCommandPaletteResponder(editor),
           editor.hasMarkedText() {
            return editor
        }

        return nil
    }

    private func isCommandPaletteEffectivelyVisible(in window: NSWindow) -> Bool {
        isCommandPaletteVisible(for: window)
            || isCommandPalettePendingOpen(for: window)
            || window.isCommandPaletteOverlayPresented
            || isCommandPaletteResponderActive(in: window)
    }

    private func activeCommandPaletteWindow() -> NSWindow? {
        pruneExpiredCommandPalettePendingOpenStates()
        if let keyWindow = shortcutRoutingKeyWindow,
           isMainTerminalWindow(keyWindow),
           isCommandPaletteEffectivelyVisible(in: keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           isMainTerminalWindow(mainWindow),
           isCommandPaletteEffectivelyVisible(in: mainWindow) {
            return mainWindow
        }
        if let orderedWindow = NSApp.orderedWindows.first(where: { window in
            isMainTerminalWindow(window) && isCommandPaletteEffectivelyVisible(in: window)
        }) {
            return orderedWindow
        }
        if let visibleWindowId = commandPalettePresentation.firstVisibleWindowId() {
            return windowForMainWindowId(visibleWindowId)
        }
        if let pendingWindowId = commandPalettePresentation.firstPendingOpenWindowId() {
            return windowForMainWindowId(pendingWindowId)
        }
        return nil
    }

    private func commandPaletteWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let scopedWindow = mainWindowForShortcutEvent(event) {
            return scopedWindow
        }
        return activeCommandPaletteWindow()
    }

    func savedLayoutSaveRequestWindow(for event: NSEvent) -> NSWindow? {
        commandPaletteWindowForShortcutEvent(event) ?? event.window ?? shortcutRoutingActiveWindow
    }

    /// Opens the diff viewer for the focused workspace of `tabManager` by spawning the
    /// bundled `cmux diff` CLI. This is the single shared diff-open path: both the
    /// command-palette entry and the Open Diff Viewer keyboard shortcut funnel through
    /// here so neither duplicates diff-open logic. Returns `false` (caller beeps) when
    /// there is no focused workspace or the bundled CLI is missing.
    @discardableResult
    func openDiffViewerForFocusedWorkspace(for tabManager: TabManager?) -> Bool {
        openDiffViewerForFocusedWorkspace(for: tabManager, preferAgentContext: true)
    }

    @discardableResult
    func openDirectoryDiffViewerForFocusedWorkspace(for tabManager: TabManager?) -> Bool {
        openDiffViewerForFocusedWorkspace(for: tabManager, preferAgentContext: false)
    }

    @discardableResult
    private func openDiffViewerForFocusedWorkspace(
        for tabManager: TabManager?,
        preferAgentContext: Bool
    ) -> Bool {
#if DEBUG
        if let debugOpenDiffViewerHandler {
            debugOpenDiffViewerHandler()
            return true
        }
#endif
        guard let workspace = tabManager?.selectedWorkspace,
              let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            return false
        }
        let socketPath = terminalControl.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let fallbackCwd = workspace.resolvedWorkingDirectory()
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        if preferAgentContext,
           let surfaceId = workspace.focusedPanelId,
           let snapshot = SharedLiveAgentIndex.shared.snapshot(workspaceId: workspace.id, panelId: surfaceId),
           let sessionId = Self.normalizedOpenDiffViewerSessionId(snapshot.sessionId) {
            let snapshotWorkingDirectory = Self.normalizedOpenDiffViewerPath(
                snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory
            )
            let storeURL = Self.agentTurnDiffBaselineStoreURL()
            let workspaceId = workspace.id
            let originWindowId = tabManager.flatMap { registeredMainWindow(forManager: $0)?.windowId }
            let taskKey = Self.openDiffViewerAgentContextTaskKey(
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                sessionId: sessionId
            )
            let request = OpenDiffViewerAgentContextRequest(
                cliURL: cliURL,
                socketPath: socketPath,
                fallbackCwd: fallbackCwd,
                snapshotWorkingDirectory: snapshotWorkingDirectory,
                storeURL: storeURL,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                sessionId: sessionId,
                originWindowId: originWindowId
            )
            if openDiffViewerAgentContextTasks[taskKey] != nil {
                openDiffViewerAgentContextPendingRequests[taskKey] = request
            } else {
                startOpenDiffViewerAgentContextTask(request, taskKey: taskKey)
            }
            return true
        }
        let agentDiffContext = preferAgentContext ? focusedAgentWorkingDirectoryContext(for: workspace) : nil
        return launchDiffViewerProcess(
            cliURL: cliURL,
            socketPath: socketPath,
            cwd: agentDiffContext?.cwd ?? fallbackCwd,
            workspaceId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            useLastTurnSource: false,
            sessionId: agentDiffContext?.sessionId,
            focus: true
        )
    }

    private func focusedAgentWorkingDirectoryContext(for workspace: Workspace) -> (cwd: String, sessionId: String?)? {
        guard let surfaceId = workspace.focusedPanelId else { return nil }
        guard let snapshot = SharedLiveAgentIndex.shared.snapshot(workspaceId: workspace.id, panelId: surfaceId) else {
            return nil
        }
        let sessionId = Self.normalizedOpenDiffViewerSessionId(snapshot.sessionId)
        if let workingDirectory = Self.normalizedOpenDiffViewerPath(
            snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory
        ) {
            return (cwd: workingDirectory, sessionId: sessionId)
        }
        return nil
    }

    func allMainWindowTabManagersForDebug() -> [TabManager] {
        environment.mainWindowRouter.allMainWindowTabManagersForDebug()
    }
#if !DEBUG
    private func debugWindowToken(_: NSWindow?) -> String { "" }
#endif

#if DEBUG
    func debugManagerToken(_ manager: TabManager?) -> String {
        guard let manager else { return "nil" }
        return String(describing: Unmanaged.passUnretained(manager).toOpaque())
    }

    private func debugWindowToken(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        let id = mainWindowId(for: window).map { String($0.uuidString.prefix(8)) } ?? "none"
        let ident = window.identifier?.rawValue ?? "nil"
        let shortIdent: String
        if ident.count > 120 {
            shortIdent = String(ident.prefix(120)) + "..."
        } else {
            shortIdent = ident
        }
        return "num=\(window.windowNumber) id=\(id) ident=\(shortIdent) key=\(window.isKeyWindow ? 1 : 0) main=\(window.isMainWindow ? 1 : 0)"
    }

    private func debugContextToken(_ context: RegisteredMainWindow?) -> String {
        guard let context else { return "nil" }
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let hasWindow = (context.window != nil || windowForMainWindowId(context.windowId) != nil) ? 1 : 0
        return "id=\(String(context.windowId.uuidString.prefix(8))) mgr=\(debugManagerToken(context.tabManager)) tabs=\(context.tabManager.tabs.count) selected=\(selected) hasWindow=\(hasWindow)"
    }

    private func debugShortcutRouteSnapshot(event: NSEvent? = nil) -> String {
        let activeManager = tabManager
        let activeWindowId = activeManager.flatMap { windowId(for: $0) }.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let selectedWorkspace = activeManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"

        let contexts = registeredMainWindows
            .map { context in
                let marker = (activeManager != nil && context.tabManager === activeManager) ? "*" : "-"
                let window = context.window ?? windowForMainWindowId(context.windowId)
                let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
                return "\(marker)\(String(context.windowId.uuidString.prefix(8))){mgr=\(debugManagerToken(context.tabManager)),win=\(window?.windowNumber ?? -1),key=\((window?.isKeyWindow ?? false) ? 1 : 0),main=\((window?.isMainWindow ?? false) ? 1 : 0),tabs=\(context.tabManager.tabs.count),selected=\(selected)}"
            }
            .sorted()
            .joined(separator: ",")

        let eventWindowNumber = event.map { String($0.windowNumber) } ?? "nil"
        let eventWindow = event?.window
        return "eventWinNum=\(eventWindowNumber) eventWin={\(debugWindowToken(eventWindow))} keyWin={\(debugWindowToken(shortcutRoutingKeyWindow))} mainWin={\(debugWindowToken(NSApp.mainWindow))} activeMgr=\(debugManagerToken(activeManager)) activeWinId=\(activeWindowId) activeSelected=\(selectedWorkspace) contexts=[\(contexts)]"
    }
#endif

    private func mainWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.window"),
           let window = resolvedWindow(for: context) {
            return window
        }
        if let window = resolvedShortcutEventWindow(event),
           isMainTerminalWindow(window) {
            return window
        }
        if let keyWindow = shortcutRoutingKeyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return nil
    }

    private func resolvedShortcutEventWindow(_ event: NSEvent) -> NSWindow? {
        if let window = event.window {
            return window
        }
        let eventWindowNumber = event.windowNumber
        guard eventWindowNumber > 0 else { return nil }
#if DEBUG
        if let window = debugShortcutRoutingFocusedWindowOverrideForTesting.window,
           window.windowNumber == eventWindowNumber {
            return window
        }
#endif
        return NSApp.window(withWindowNumber: eventWindowNumber)
    }

    private func mainWindowForFocusedCloseShortcut(event: NSEvent) -> NSWindow? {
        // Close shortcuts are focused-window commands. Some AppKit key-equivalent
        // paths can preserve stale event window metadata after a new window becomes
        // key, so prefer the actual focused window before falling back to event data.
        if let keyWindow = shortcutRoutingKeyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        return mainWindowForShortcutEvent(event)
    }

    private func tabManagerForFocusedCloseShortcut(event: NSEvent) -> TabManager? {
        if let targetWindow = mainWindowForFocusedCloseShortcut(event: event) {
            return synchronizeActiveMainWindowContext(preferredWindow: targetWindow)
        }
        return preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
    }

    private func auxiliaryWindowForFocusedCloseShortcut(event: NSEvent) -> NSWindow? {
        [
            shortcutRoutingKeyWindow,
            NSApp.mainWindow,
            resolvedShortcutEventWindow(event),
        ]
        .compactMap { $0 }
        .first { AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut($0.identifier?.rawValue) }
    }

    /// Re-sync app-level active window pointers from the currently focused main terminal window.
    /// This keeps menu/shortcut actions window-scoped even if the cached `tabManager` drifts.
    @discardableResult
    func synchronizeActiveMainWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        environment.mainWindowRouter.synchronizeActiveWindowContext(preferredWindow: preferredWindow)
    }

    private struct FocusedTerminalShortcutContext {
        let tabManager: TabManager
        let workspaceId: UUID
        let panelId: UUID
    }

    private func resolveShortcutTabManager(for tabId: UUID, preferredWindow: NSWindow? = nil) -> TabManager? {
        if let manager = tabManagerFor(tabId: tabId) {
            return manager
        }
        if let preferredWindow,
           let context = contextForMainWindow(preferredWindow),
           context.tabManager.tabs.contains(where: { $0.id == tabId }) {
            return context.tabManager
        }
        if let activeManager = tabManager,
           activeManager.tabs.contains(where: { $0.id == tabId }) {
            return activeManager
        }
        return nil
    }

    /// The focused workspace/surface for the focused-mark flow, resolved exactly
    /// as the legacy `focusedNotificationTarget(preferredWindow:)` did: the
    /// first-responder terminal, else the preferred/key/main window's selected
    /// tab, else the active tab manager. Returns `(tabId, surfaceId)` so the
    /// `FocusedNotificationResolving` seam adapter (a separate file) can build the
    /// package's value-typed target without reaching the private
    /// `FocusedTerminalShortcutContext`.
    func resolveFocusedNotificationTarget(preferredWindow: NSWindow?) -> (tabId: UUID, surfaceId: UUID?)? {
        if let terminalContext = focusedTerminalShortcutContext(preferredWindow: preferredWindow) {
            return (terminalContext.workspaceId, terminalContext.panelId)
        }

        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        if let context = contextForMainWindow(targetWindow),
           let selectedTabId = context.tabManager.selectedTabId ?? context.tabManager.tabs.first?.id {
            return (selectedTabId, context.tabManager.focusedSurfaceId(for: selectedTabId))
        }

        if let activeManager = tabManager,
           let selectedTabId = activeManager.selectedTabId ?? activeManager.tabs.first?.id {
            return (selectedTabId, activeManager.focusedSurfaceId(for: selectedTabId))
        }

        return nil
    }

    private func focusedTerminalShortcutContext(preferredWindow: NSWindow? = nil) -> FocusedTerminalShortcutContext? {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let responder = shortcutRoutingFirstResponder(preferredWindow: targetWindow)
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id,
              let manager = resolveShortcutTabManager(for: workspaceId, preferredWindow: targetWindow) else {
            return nil
        }
        return FocusedTerminalShortcutContext(
            tabManager: manager,
            workspaceId: workspaceId,
            panelId: panelId
        )
    }

    private func preferredMainWindowContextForShortcuts(event: NSEvent) -> RegisteredMainWindow? {
        if let context = contextForMainWindow(event.window) {
            return context
        }
        if let context = contextForMainWindow(shortcutRoutingKeyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = registeredMainWindow(forManager: activeManager) {
            return activeContext
        }
        return registeredMainWindows.first
    }

    func preferredRegisteredMainWindowContext(preferredWindow: NSWindow? = nil) -> RegisteredMainWindow? {
        environment.mainWindowRouter.preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)
    }

    private func activateMainWindowContextForShortcutEvent(_ event: NSEvent) {
        let preferredWindow = mainWindowForShortcutEvent(event)
#if DEBUG
        cmuxDebugLog(
            "shortcut.activate.pre event=\(event.cmuxKeyDescription) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        _ = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
#if DEBUG
        cmuxDebugLog(
            "shortcut.activate.post event=\(event.cmuxKeyDescription) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
    }

    @discardableResult
    func toggleSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        environment.mainWindowRouter.toggleSidebarInActiveWindow(preferredWindow: preferredWindow)
    }

    @discardableResult
    func toggleRightSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        environment.mainWindowRouter.toggleRightSidebarInActiveWindow(preferredWindow: preferredWindow)
    }

    @discardableResult
    func closeRightSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        environment.mainWindowRouter.closeRightSidebarInActiveWindow(preferredWindow: preferredWindow)
    }

    @discardableResult
    func restoreTerminalFocusAfterRightSidebarHidden(in window: NSWindow?) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: window)
        return context?.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded() ?? false
    }

    @discardableResult
    func restoreFocusedMainPanelFocusFromRightSidebar(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId) ?? preferredWindow
        if let window {
            setActiveMainWindow(window)
        }
        return context.keyboardFocusCoordinator.restoreFocusedPanelFocusFromRightSidebarIfNeeded(
            currentResponder: window?.firstResponder
        )
    }

    @discardableResult
    private func restoreFocusedMainPanelFocusForShortcut(event: NSEvent) -> Bool {
        let preferredWindow = mainWindowForShortcutEvent(event) ?? event.window ?? shortcutRoutingActiveWindow
        return restoreFocusedMainPanelFocusFromRightSidebar(preferredWindow: preferredWindow)
    }

    func keyboardFocusCoordinator(for window: NSWindow?) -> MainWindowFocusController? {
        guard let window else { return nil }
        return contextForMainWindow(window)?.keyboardFocusCoordinator
            ?? contextForMainTerminalWindow(window)?.keyboardFocusCoordinator
    }

    func isRightSidebarFocusResponder(_ responder: NSResponder, in window: NSWindow?) -> Bool {
        // A responder reparented out of `window` (stranded) is not this window's right-sidebar focus
        // owner even when its type matches `ownsRightSidebarFocus`. Requiring window membership keeps a
        // stranded host from being treated as a legitimate focus owner that blocks focus recovery
        // (issue #5269).
        guard let window, (responder as? NSView)?.window === window else { return false }
        return keyboardFocusCoordinator(for: window)?.ownsRightSidebarFocus(responder) == true
    }

    func shouldRouteRightSidebarModeShortcut(in window: NSWindow?) -> Bool {
        guard let window,
              let responder = window.firstResponder else {
            return false
        }
        if isRightSidebarFocusResponder(responder, in: window) {
            return true
        }
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let panelId = ghosttyView.terminalSurface?.id else {
            return false
        }
        return GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: panelId)
    }

    func allowsTerminalKeyboardFocus(
        workspaceId: UUID,
        panelId: UUID,
        in window: NSWindow?
    ) -> Bool {
        keyboardFocusCoordinator(for: window)?.allowsTerminalFocus(workspaceId: workspaceId, panelId: panelId) ?? true
    }

    func syncBonsplitTabShortcutHintEligibility(in window: NSWindow?) {
        if let coordinator = keyboardFocusCoordinator(for: window) {
            coordinator.syncBonsplitTabShortcutHintEligibility()
            return
        }
        for context in registeredMainWindows {
            context.keyboardFocusCoordinator.syncBonsplitTabShortcutHintEligibility()
        }
    }

    fileprivate struct TerminalKeyboardFocusRequest {
        let workspaceId: UUID
        let panelId: UUID
        let ghosttyView: GhosttyNSView
    }

    fileprivate func terminalKeyboardFocusRequest(for responder: NSResponder?) -> TerminalKeyboardFocusRequest? {
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        if GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: panelId) {
            return nil
        }
        return TerminalKeyboardFocusRequest(
            workspaceId: workspaceId,
            panelId: panelId,
            ghosttyView: ghosttyView
        )
    }

    func allowsTerminalKeyboardFocus(for responder: NSResponder?, in window: NSWindow?) -> Bool {
        guard let request = terminalKeyboardFocusRequest(for: responder) else {
            return true
        }
        return allowsTerminalKeyboardFocus(
            workspaceId: request.workspaceId,
            panelId: request.panelId,
            in: window
        )
    }

    func noteTerminalKeyboardFocusIntent(workspaceId: UUID, panelId: UUID, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteTerminalInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteMainPanelKeyboardFocusIntent(workspaceId: UUID, panelId: UUID, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteRightSidebarKeyboardFocusIntent(mode: RightSidebarMode, in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteRightSidebarInteraction(mode: mode)
    }

    func syncKeyboardFocusAfterFirstResponderChange(in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.syncAfterResponderChange()
    }

    @discardableResult
    func focusRightSidebarInActiveMainWindow(
        mode requestedMode: RightSidebarMode? = nil,
        focusFirstItem: Bool = true,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        environment.mainWindowRouter.focusRightSidebarInActiveWindow(
            mode: requestedMode,
            focusFirstItem: focusFirstItem,
            preferredWindow: preferredWindow
        )
    }

#if DEBUG
    func debugRevealRightSidebarInActiveMainWindow(
        mode: RightSidebarMode,
        focusFirstItem: Bool,
        preferredWindow: NSWindow? = nil
    ) -> (
        revealed: Bool,
        focusApplied: Bool,
        contextFound: Bool,
        stateFound: Bool,
        visible: Bool,
        activeMode: String?
    ) {
        environment.mainWindowRouter.debugRevealRightSidebarInActiveWindow(
            mode: mode,
            focusFirstItem: focusFirstItem,
            preferredWindow: preferredWindow
        )
    }
#endif

    @discardableResult
    func focusFileSearchInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        environment.mainWindowRouter.focusFileSearchInActiveWindow(preferredWindow: preferredWindow)
    }

    @discardableResult
    func performFindShortcutInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        environment.mainWindowRouter.performFindInActiveWindow(preferredWindow: preferredWindow)
    }

    @discardableResult
    func toggleRightSidebarKeyboardFocusInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        environment.mainWindowRouter.toggleRightSidebarKeyboardFocusInActiveWindow(preferredWindow: preferredWindow)
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        guard let context = registeredMainWindow(forWindowId: windowId) else {
            return nil
        }
        return sidebarState(for: context).isVisible
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let spec = appMenuCoordinator.dockMenuSpec(
            newWindowTitle: String(localized: "menu.file.newWindow", defaultValue: "New Window")
        )
        return materializeAppMenu(spec)
    }

    /// Materializes an ``AppMenuCoordinator`` ``DockMenuSpec`` into a live
    /// `NSMenu`, binding each item's `@objc` selector and `target` app-side (the
    /// coordinator emits only the Sendable value description).
    private func materializeAppMenu(_ spec: DockMenuSpec) -> NSMenu {
        let menu = NSMenu(title: "")
        for item in spec.items {
            switch item.action {
            case .separator:
                menu.addItem(.separator())
            case .newMainWindow:
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(openNewMainWindow(_:)),
                    keyEquivalent: item.keyEquivalent
                )
                if !item.keyEquivalent.isEmpty {
                    menuItem.keyEquivalentModifierMask = item.modifierMask
                }
                menuItem.target = self
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    @objc func openNewMainWindow(_ sender: Any?) {
        _ = createMainWindow(sourceWindow: preferredSourceWindowForNewMainWindow(sender: sender))
    }

    func openNewMainWindow(preferredWindow: NSWindow?) {
        _ = createMainWindow(sourceWindow: preferredWindow)
    }

    private func preferredSourceWindowForNewMainWindow(sender: Any?) -> NSWindow? {
        if let window = sender as? NSWindow, isMainTerminalWindow(window) {
            return window
        }
        if let event = currentKeyboardShortcutEvent(),
           let window = mainWindowForShortcutEvent(event) {
            return window
        }
        if let keyWindow = shortcutRoutingKeyWindow, isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        if let context = preferredRegisteredMainWindowContext(),
           let window = resolvedWindow(for: context) {
            return window
        }
        return nil
    }

    private func currentKeyboardShortcutEvent() -> NSEvent? {
        guard let event = NSApp.currentEvent,
              event.type == .keyDown || event.type == .keyUp else {
            return nil
        }
        return event
    }

    func scheduleInitialMainWindowBootstrap(debugSource: String) {
        guard !didScheduleInitialMainWindowBootstrap else { return }
        didScheduleInitialMainWindowBootstrap = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.shouldDeferInitialMainWindowBootstrapForExternalConfirmation { self.didScheduleInitialMainWindowBootstrap = false; return }
            self.bootstrapInitialMainWindowIfNeeded(debugSource: debugSource)
        }
    }

    @discardableResult
    func bootstrapInitialMainWindowIfNeeded(
        debugSource: String,
        shouldActivate: Bool = true,
        suppressWelcome: Bool = false
    ) -> UUID {
        reserveInitialSocketPathIfNeeded()
        let windowId = ensureInitialMainWindowIfNeeded(
            shouldActivate: shouldActivate,
            suppressWelcome: suppressWelcome
        )
        if let manager = tabManagerFor(windowId: windowId)
            ?? registeredMainWindow(forWindowId: windowId)?.tabManager
            ?? preferredRegisteredMainWindowContext()?.tabManager
            ?? registeredMainWindows.first?.tabManager {
            startSocketListenerIfEnabled(
                tabManager: manager,
                source: "bootstrapInitialMainWindow.\(debugSource)"
            )
            MobileHostService.shared.start()
        }
        guard !didBootstrapInitialMainWindow else { return windowId }

        didBootstrapInitialMainWindow = true
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_SHOW_SETTINGS"] == "1" {
            openPreferencesWindow(debugSource: "uiTestShowSettings.\(debugSource)")
        }
        return windowId
    }

    @discardableResult
    func ensureInitialMainWindowIfNeeded(
        shouldActivate: Bool = true,
        suppressWelcome: Bool = false
    ) -> UUID {
        for context in sortedMainWindowContextsForSessionSnapshot() {
            guard let window = resolvedWindow(for: context) else { continue }
            if shouldActivate {
                mainWindowVisibilityController.focus(
                    window,
                    reason: .ensureInitialWindow,
                    activation: .none,
                    respectActivationSuppression: false
                )
            }
            return context.windowId
        }

        return createMainWindow(
            initialTerminalInput: suppressWelcome ? "" : nil,
            preferredWindowId: startupPrimaryWindowIdForInitialMainWindow(),
            shouldActivate: shouldActivate
        )
    }

    // Internal (not private) so the `ApplicationActivationHost` conformance in
    // `AppDelegate+ApplicationActivationHost.swift` can witness the activation
    // visibility methods.
    func hasVisibleMainTerminalWindow() -> Bool {
        registeredMainWindows.contains { context in
            guard let window = resolvedWindow(for: context) else { return false }
            return window.isVisible && !window.isMiniaturized && window.alphaValue > 0.001
        }
    }

    /// Creates a new terminal-initial workspace, routing to the right window.
    /// Thin forward to ``WorkspaceCreationActionCoordinator`` (CmuxWorkspaces),
    /// which owns the routing decision logic; the app inputs cross as the opaque
    /// ``WorkspaceCreationActionSelector``.
    @discardableResult
    func performNewWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "newWorkspace"
    ) -> Bool {
        workspaceCreationActions.performNewWorkspaceAction(
            selector: WorkspaceCreationActionSelector(
                preferredTabManager: preferredTabManager,
                event: event,
                preferredWindow: nil
            ),
            debugSource: debugSource
        )
    }

    /// Creates a new workspace whose initial surface is a browser pane in its
    /// default new-tab state with the address bar focused. Shares the window
    /// routing, placement, and naming semantics of `performNewWorkspaceAction`.
    /// Thin forward to ``WorkspaceCreationActionCoordinator`` (CmuxWorkspaces).
    @discardableResult
    func performNewBrowserWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "newBrowserWorkspace"
    ) -> Bool {
        workspaceCreationActions.performNewBrowserWorkspaceAction(
            selector: WorkspaceCreationActionSelector(
                preferredTabManager: preferredTabManager,
                event: event,
                preferredWindow: nil
            ),
            debugSource: debugSource
        )
    }

    @discardableResult
    func performProUpgradeWorkspaceAction(
        title: String,
        url: URL,
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "proUpgradeWorkspace"
    ) -> Workspace? {
        guard BrowserAvailabilitySettings.isEnabled() else {
#if DEBUG
            cmuxDebugLog("proUpgradeWorkspace.blocked_browser_disabled source=\(debugSource)")
#endif
            return nil
        }
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        guard let context else {
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            discardOrphanedMainWindowContext(context)
            return nil
        }
        setActiveMainWindow(window)
        let workspace = context.tabManager.addWorkspace(
            title: title,
            initialSurface: .browser,
            initialBrowserURL: url,
            initialBrowserOmnibarVisible: false,
            initialBrowserTransparentBackground: true,
            select: true
        )
        focusInitialBrowserWebView(in: workspace)
        return workspace
    }

    func proUpgradeWorkspaceExists(workspaceId: UUID) -> Bool {
        registeredMainWindows.contains { context in
            context.tabManager.tabs.contains { $0.id == workspaceId }
        } || (tabManager?.tabs.contains { $0.id == workspaceId } == true)
    }

    @discardableResult
    func focusProUpgradeWorkspace(workspaceId: UUID, url: URL) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else { return false }
        guard let (context, workspace) = proUpgradeWorkspaceContext(workspaceId: workspaceId) else {
            return false
        }
        guard let window = resolvedWindow(for: context) else {
            return false
        }
        guard focusWindowForAppActivation(window, reason: .workspaceCreation) else {
            return false
        }
        context.tabManager.selectedTabId = workspace.id
        guard let browserPanel = workspace.focusedSurfaceId.flatMap({ workspace.browserPanel(for: $0) })
            ?? workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first else {
            return false
        }
        workspace.focusPanel(browserPanel.id)
        browserPanel.navigate(to: url)
        browserPanel.requestExplicitWebViewFocus()
        context.tabManager.rememberFocusedSurface(tabId: workspace.id, surfaceId: browserPanel.id)
        return true
    }

    private func proUpgradeWorkspaceContext(workspaceId: UUID) -> (RegisteredMainWindow, Workspace)? {
        for context in registeredMainWindows {
            if let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }) {
                return (context, workspace)
            }
        }
        if let tabManager,
           let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
           let context = mainWindowContext(for: tabManager) {
            return (context, workspace)
        }
        return nil
    }

    private func focusInitialBrowserWebView(in workspace: Workspace) {
        guard let browserPanel = workspace.focusedSurfaceId.flatMap({ workspace.browserPanel(for: $0) })
            ?? workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first else {
            return
        }
        workspace.focusPanel(browserPanel.id)
        browserPanel.requestExplicitWebViewFocus()
        workspace.owningTabManager?.rememberFocusedSurface(tabId: workspace.id, surfaceId: browserPanel.id)
    }

    @discardableResult
    func performCloudVMAction(
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "cloudVM",
        onCompletion: ((CloudVMActionCompletion) -> Void)? = nil
    ) -> Bool {
        workspaceCreationActions.performCloudVMAction(
            selector: WorkspaceCreationActionSelector(
                preferredTabManager: preferredTabManager,
                event: nil,
                preferredWindow: preferredWindow
            ),
            debugSource: debugSource,
            onCompletion: onCompletion
        )
    }

    @discardableResult
    func performCurrentCloudVMCommand(
        _ command: CurrentCloudVMCommand,
        tabManager preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "cloudVM.current"
    ) -> Bool {
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context else {
            NSSound.beep()
            return false
        }
        guard let vmId = currentCloudVMId(tabManager: context.tabManager) else {
            presentCloudVMNotice(
                title: String(localized: "command.cloudVM.current.missing.title", defaultValue: "No Cloud VM Selected"),
                message: String(localized: "command.cloudVM.current.missing.message", defaultValue: "Select a Cloud VM workspace first, then retry this command."),
                preferredWindow: resolvedWindow(for: context) ?? preferredWindow
            )
            return false
        }
        let socketPath = terminalControl.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: resolvedWindow(for: context) ?? preferredWindow,
            arguments: command.arguments(vmId: vmId),
            successTitle: command.successTitle,
            presentOutputOnSuccess: command.presentOutputOnSuccess
        )
    }

    @discardableResult
    func performCloudVMRestoreCommand(
        preferredWindow: NSWindow? = nil,
        debugSource: String = "cloudVM.restore"
    ) -> Bool {
        let context = preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context else {
            NSSound.beep()
            return false
        }
        let window = resolvedWindow(for: context) ?? preferredWindow
        guard let snapshotId = promptForCloudVMSnapshotId(preferredWindow: window) else {
            return false
        }
        let socketPath = terminalControl.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        return CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: window,
            arguments: ["vm", "restore", snapshotId],
            successTitle: String(localized: "command.cloudVM.restore.result.title", defaultValue: "Cloud VM Restored"),
            presentOutputOnSuccess: true
        )
    }

    enum CurrentCloudVMCommand {
        case status
        case fork
        case snapshot
        case ports
        case tools
        case handoff
        case promoteTemplate

        var successTitle: String {
            switch self {
            case .status:
                return String(localized: "command.cloudVM.status.result.title", defaultValue: "Cloud VM Status")
            case .fork:
                return String(localized: "command.cloudVM.fork.result.title", defaultValue: "Cloud VM Forked")
            case .snapshot:
                return String(localized: "command.cloudVM.snapshot.result.title", defaultValue: "Cloud VM Checkpoint")
            case .ports:
                return String(localized: "command.cloudVM.ports.result.title", defaultValue: "Cloud VM Ports")
            case .tools:
                return String(localized: "command.cloudVM.tools.result.title", defaultValue: "Cloud VM Tools")
            case .handoff:
                return String(localized: "command.cloudVM.handoff.result.title", defaultValue: "Cloud VM Handoff")
            case .promoteTemplate:
                return String(localized: "command.cloudVM.template.result.title", defaultValue: "Cloud VM Template")
            }
        }

        var presentOutputOnSuccess: Bool {
            switch self {
            case .fork:
                return false
            case .status, .snapshot, .ports, .tools, .handoff, .promoteTemplate:
                return true
            }
        }

        func arguments(vmId: String) -> [String] {
            switch self {
            case .status:
                return ["vm", "status", vmId]
            case .fork:
                return ["vm", "fork", vmId]
            case .snapshot:
                return ["vm", "snapshot", vmId]
            case .ports:
                return ["vm", "ports", vmId]
            case .tools:
                return ["vm", "tools", vmId]
            case .handoff:
                return ["vm", "handoff", vmId]
            case .promoteTemplate:
                return ["vm", "promote-template", vmId]
            }
        }
    }

    private func currentCloudVMId(tabManager: TabManager) -> String? {
        guard let workspaceId = tabManager.selectedTabId,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              let vmID = workspace.remoteConfiguration?.managedCloudVMID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !vmID.isEmpty else {
            return nil
        }
        return vmID
    }

    private func promptForCloudVMSnapshotId(preferredWindow: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "command.cloudVM.restore.prompt.title", defaultValue: "Restore Cloud VM")
        alert.informativeText = String(localized: "command.cloudVM.restore.prompt.message", defaultValue: "Paste a checkpoint or snapshot id to restore.")
        alert.addButton(withTitle: String(localized: "common.restore", defaultValue: "Restore"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = String(localized: "command.cloudVM.restore.prompt.placeholder", defaultValue: "snapshot-id")
        alert.accessoryView = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let snapshotId = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshotId.isEmpty ? nil : snapshotId
    }

    private func presentCloudVMNotice(title: String, message: String, preferredWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        if let preferredWindow {
            alert.beginSheetModal(for: preferredWindow, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    // Relaxed from `private` to `internal` so the `WorkspaceCreationActionHosting`
    // witnesses in AppDelegate+WorkspaceCreationActionHosting.swift can reach it.
    func mainWindowContext(for tabManager: TabManager) -> RegisteredMainWindow? {
        registeredMainWindow(forManager: tabManager)
    }

    /// Witness for ``WorkspaceCreationActionHosting/executeConfiguredNewWorkspaceActionIfAvailable(in:debugSource:replacingInitialWorkspaceId:target:)``.
    /// The configured-action machinery (config-store read, the in-group
    /// async-join observer, the `executeConfiguredCmuxAction` dispatch) is
    /// irreducibly app-coupled, so this stays app-side; the coordinator decides
    /// whether/where to invoke it. Resolves the `WindowID` token back to its
    /// live `MainWindowContext` via the kept live-state seam.
    func executeConfiguredNewWorkspaceActionIfAvailable(
        in windowToken: WindowID,
        debugSource: String,
        replacingInitialWorkspaceId initialWorkspaceId: UUID?,
        target workspaceGroupTarget: WorkspaceGroupNewWorkspaceTarget?
    ) -> Bool {
        guard let context = registeredMainWindows.first(where: {
            WindowID($0.windowId) == windowToken
        }) else {
            return false
        }
        guard let cmuxConfigStore = windowRegistry.context(for: WindowID(context.windowId))?.configStore,
              let action = cmuxConfigStore.resolvedNewWorkspaceAction() else {
            return false
        }
        guard let window = resolvedWindow(for: context) else {
            discardOrphanedMainWindowContext(context)
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "newWorkspace.configCommand source=\(debugSource) " +
            "action=\(action.id) windowId=\(String(context.windowId.uuidString.prefix(8)))"
        )
#endif
        if let workspaceGroupTarget,
           case .builtIn(.newWorkspace) = action.action {
            return context.tabManager.createWorkspaceInGroup(
                groupId: workspaceGroupTarget.groupId,
                placement: workspaceGroupTarget.placement,
                referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
            ) != nil
        }

        let beforeIds = workspaceGroupTarget.map { _ in Set(context.tabManager.tabs.map(\.id)) }
        let actionCreatesWorkspace = action.workspaceCommandName != nil
            || action.action.inlineWorkspace != nil
            || action.action == .builtIn(.newAgentChat)
        // `context` is now an ephemeral value (`RegisteredMainWindow`), so it
        // cannot be captured `weak`. Capture its `WindowID` and re-resolve inside
        // the deferred closure: the resolver returns `nil` once the window has
        // torn down, faithfully reproducing the old `[weak context]` "skip if the
        // window is gone" semantics (the manager outlives the value either way).
        let contextWindowId = WindowID(context.windowId)
        var asyncObserverId: UUID?
        let onExecuted: (() -> Void)? = (!actionCreatesWorkspace && workspaceGroupTarget == nil) ? nil : { [weak self] in
            let context = self?.registeredMainWindow(for: contextWindowId)
            if let context,
               let workspaceGroupTarget,
               let beforeIds {
                let afterIds = context.tabManager.tabs.map(\.id)
                var newlyCreatedId: UUID?
                for id in afterIds where !beforeIds.contains(id) {
                    context.tabManager.addWorkspaceToGroup(
                        workspaceId: id,
                        groupId: workspaceGroupTarget.groupId,
                        placement: workspaceGroupTarget.placement,
                        referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
                    )
                    newlyCreatedId = id
                    break
                }
                if newlyCreatedId == nil, case .builtIn(.cloudVM) = action.action {
                    asyncObserverId = self?.workspaceGroupJoinCoordinator.install(
                        host: context.tabManager,
                        groupId: workspaceGroupTarget.groupId,
                        knownIds: Set(afterIds),
                        placement: workspaceGroupTarget.placement,
                        referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
                    )
                }
            }
            if actionCreatesWorkspace {
                self?.workspaceCreationActions.closeInitialWorkspaceIfNeeded(
                    initialWorkspaceId: initialWorkspaceId,
                    in: context.map { WindowID($0.windowId) }
                )
            }
        }
        let onCloudVMCompletion: ((CloudVMActionCompletion) -> Void)? = workspaceGroupTarget == nil ? nil : { [weak self] completion in
            guard let self, let context = self.registeredMainWindow(for: contextWindowId), let asyncObserverId else { return }
            self.workspaceGroupJoinCoordinator.finishPending(
                host: context.tabManager,
                observerId: asyncObserverId,
                workspaceId: completion.succeeded ? completion.workspaceId : nil
            )
        }
        return executeConfiguredCmuxAction(
            action,
            context: context,
            preferredWindow: window,
            onExecuted: onExecuted,
            onCloudVMCompletion: onCloudVMCompletion
        )
    }

    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        event: NSEvent,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? mainWindowContext(forShortcutEvent: event, debugSource: debugSource)
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        guard let context,
              let cmuxConfigStore = windowRegistry.context(for: WindowID(context.windowId))?.configStore else {
            return false
        }

        let configuredItems = cmuxConfigStore.newWorkspaceContextMenuItems
        guard !configuredItems.isEmpty else { return false }

        let inputs: [NewWorkspaceContextMenuItemInput] = configuredItems.enumerated().map { index, configuredItem in
            switch configuredItem {
            case .separator:
                return .separator
            case .action(let menuAction):
                return .action(
                    title: menuAction.title,
                    tooltip: menuAction.tooltip,
                    iconSourcePath: menuAction.iconSourcePath,
                    actionIndex: index
                )
            }
        }
        guard let plan = appMenuCoordinator.planNewWorkspaceContextMenu(items: inputs) else {
            return false
        }

        let menu = NSMenu()
        for planItem in plan {
            switch planItem {
            case .separator:
                menu.addItem(.separator())
            case .action(_, _, _, let actionIndex):
                guard case .action(let menuAction) = configuredItems[actionIndex] else { continue }
                let item = NSMenuItem(
                    title: menuAction.title,
                    action: #selector(performNewWorkspaceContextMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NewWorkspaceContextMenuActionBox(
                    windowId: context.windowId,
                    action: menuAction.action
                )
                item.toolTip = menuAction.tooltip
                item.image = menuAction.icon?.contextMenuImage(
                    configSourcePath: menuAction.iconSourcePath,
                    globalConfigPath: cmuxConfigStore.globalConfigPath
                )
                menu.addItem(item)
            }
        }

        NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        return true
    }

    @objc private func performNewWorkspaceContextMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? NewWorkspaceContextMenuActionBox,
              let context = registeredMainWindows.first(where: { $0.windowId == box.windowId }),
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        guard executeConfiguredCmuxAction(box.action, context: context, preferredWindow: window) else {
            NSSound.beep()
            return
        }
    }

    /// Shows the "Open Folder" panel and creates a workspace for the selected directory.
    /// Called from both the SwiftUI menu and `handleCustomShortcut`.
    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "menu.file.openFolder.panelTitle", defaultValue: "Open Folder")
        panel.prompt = String(localized: "menu.file.openFolder.panelPrompt", defaultValue: "Open")
        // Seed the panel with the active workspace's directory. Use the shared
        // main-window resolver so this works even when an auxiliary window is key.
        if let context = preferredMainWindowContextForWorkspaceCreation(debugSource: "openFolderPanel.seed"),
           let cwd = context.tabManager.selectedWorkspace?.currentDirectory,
           !cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }
        if panel.runModal() == .OK, let url = panel.url {
            externalOpenIntentCoordinator.openWorkspace(
                forExternalDirectory: url.path,
                debugSource: "shortcut.openFolder"
            )
        }
    }

    @discardableResult
    func openDirectoryInInlineVSCode(
        _ directoryURL: URL,
        tabManager preferredTabManager: TabManager? = nil
    ) -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }

        let targetTabManager = preferredTabManager
            ?? preferredMainWindowContextForWorkspaceCreation(debugSource: "inlineVSCode.open.target")?.tabManager
        guard let targetTabManager else {
            return false
        }

        let targetWorkspaceId = targetTabManager.selectedWorkspace?.id
            ?? targetTabManager.tabs.first?.id
            ?? targetTabManager.addWorkspace(select: true).id
        let normalizedDirectoryURL = directoryURL.standardizedFileURL

        vscodeServeWebController.ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            guard let serveWebURL,
                  let openFolderURL = serveWebURL.vscodeServeWebFolderURL(
                      directoryPath: normalizedDirectoryURL.path
                  ) else {
                NSSound.beep()
                return
            }

            guard targetTabManager.openBrowser(
                inWorkspace: targetWorkspaceId,
                url: openFolderURL,
                preferSplitRight: true
            ) != nil else {
                NSSound.beep()
                return
            }
        }

        return true
    }

    func showOpenFolderInInlineVSCodePanel(tabManager preferredTabManager: TabManager? = nil) {
        guard TerminalDirectoryOpenTarget.vscodeInline.isAvailable() else {
            NSSound.beep()
            return
        }

        let targetTabManager = preferredTabManager
            ?? preferredMainWindowContextForWorkspaceCreation(debugSource: "inlineVSCode.panel.target")?.tabManager
        guard let targetTabManager else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "menu.file.openFolderInVSCodeInline.panelTitle",
            defaultValue: "Open Folder in VS Code (Inline)"
        )
        panel.prompt = String(
            localized: "menu.file.openFolderInVSCodeInline.panelPrompt",
            defaultValue: "Open in VS Code"
        )
        if let cwd = targetTabManager.selectedWorkspace?.currentDirectory,
           !cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }

        if panel.runModal() == .OK,
           let url = panel.url,
           !openDirectoryInInlineVSCode(url, tabManager: targetTabManager) {
            NSSound.beep()
        }
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .window, error: error)
    }

    // Conformance witnesses (`createMainWindowForExternalOpen`,
    // `addWorkspaceInPreferredMainWindowForExternalOpen`,
    // `prepareForExplicitOpenIntentAtStartup`) are defined below in this file.

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .workspace, error: error)
    }

    /// Thin app-target host for ``ExternalOpenIntentCoordinator``: the three
    /// app-only effects the package decision/loop forwards back here.
    /// `prepareForExplicitOpenIntentAtStartup()` is the existing method below.
    func createMainWindowForExternalOpen(workingDirectory: String) {
        _ = createMainWindow(initialWorkingDirectory: workingDirectory)
    }

    func addWorkspaceInPreferredMainWindowForExternalOpen(
        workingDirectory: String,
        debugSource: String
    ) -> Bool {
        addWorkspaceInPreferredMainWindow(
            workingDirectory: workingDirectory,
            shouldBringToFront: true,
            debugSource: debugSource
        ) != nil
    }

    private func openFromServicePasteboard(
        _ pasteboard: NSPasteboard,
        target: ServiceOpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let pathURLs = servicePathURLs(from: pasteboard)
        guard !pathURLs.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        let directories = externalOpenURLClassifier.directories(from: pathURLs)
        guard !directories.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        externalOpenIntentCoordinator.open(directories: directories, target: target)
    }

    private func servicePathURLs(from pasteboard: NSPasteboard) -> [URL] {
        serviceOpenResolver.pathURLs(from: pasteboard)
    }

    func prepareForExplicitOpenIntentAtStartup() {
        didHandleExplicitOpenIntentAtStartup = true
        if !didAttemptStartupSessionRestore {
            startupSessionSnapshot = nil
            didAttemptStartupSessionRestore = true
            // Explicit open intent cancels restore; deferred links cannot gain targets.
            flushPendingStartupNavigationURLRequests()
        }
    }

    func openTerminalDefaultFileRequest(
        _ request: TerminalDefaultFileOpenRequest,
        debugSource: String
    ) {
        if addWorkspaceInPreferredMainWindow(
            workingDirectory: request.workingDirectory,
            initialTerminalInput: request.initialInput,
            shouldBringToFront: true,
            debugSource: debugSource
        ) != nil {
            return
        }
        _ = createMainWindow(
            initialWorkspaceTitle: request.fileURL.lastPathComponent,
            initialWorkingDirectory: request.workingDirectory,
            initialTerminalInput: request.initialInput
        )
    }

    @discardableResult
    func pasteTextInPreferredMainWindowFromExternalLink(
        _ text: String,
        preferredWindow: NSWindow? = nil,
        shouldBringToFront: Bool = true,
        debugSource: String = "externalLink",
        onSendFailure: (() -> Void)? = nil
    ) -> Bool {
        let context: RegisteredMainWindow? = {
            if let existing = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) {
                return existing
            }
            let windowId = createMainWindow(initialTerminalInput: "", shouldActivate: shouldBringToFront)
            return registeredMainWindow(forWindowId: windowId)
        }()
        guard let context else { return false }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if shouldBringToFront, let window {
            bringToFront(window)
            setActiveMainWindow(window)
        }

        let workspace = context.tabManager.selectedWorkspace
            ?? context.tabManager.addWorkspace(select: shouldBringToFront, autoWelcomeIfNeeded: false)
        // In a remote tmux mirror workspace, paste targets the existing focused
        // pane. Do NOT fall back to creating a new surface there: that would
        // route to a remote `new-window` (a surprising side effect) yet still
        // have no local pane to deliver the text to.
        let terminalPanel = workspace.focusedTerminalPanel
            ?? (workspace.isRemoteTmuxMirror ? nil : workspace.newTerminalSurfaceInFocusedPane(focus: shouldBringToFront))
        guard let terminalPanel else { return false }

#if DEBUG
        cmuxDebugLog("textURL.paste source=\(debugSource) workspace=\(workspace.id.uuidString.prefix(8)) surface=\(terminalPanel.id.uuidString.prefix(8)) chars=\(text.count)")
#endif
        if shouldBringToFront {
            workspace.focusPanel(terminalPanel.id)
        }
        sendTextWhenReady(
            text,
            to: workspace,
            preferredPanelId: terminalPanel.id,
            onFailure: onSendFailure
        )
        return true
    }

    @discardableResult
    func openFilePreviewInPreferredMainWindow(
        filePath: String,
        preferredWindow: NSWindow? = nil,
        debugSource: String = "unspecified"
    ) -> Bool {
        let parentDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
        let context: RegisteredMainWindow? = {
            if let existing = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) {
                return existing
            }
            let windowId = createMainWindow(initialWorkingDirectory: parentDirectory)
            return registeredMainWindow(forWindowId: windowId)
        }()
        guard let context else { return false }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            bringToFront(window)
            setActiveMainWindow(window)
        }

        let workspace = context.tabManager.selectedWorkspace
            ?? context.tabManager.addWorkspace(workingDirectory: parentDirectory, select: true)
        guard let paneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }

#if DEBUG
        cmuxDebugLog("file.externalOpen source=\(debugSource) path=\(filePath)")
#endif
        return !workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: true,
            reuseExisting: true
        ).isEmpty
    }

    @discardableResult
    func addWorkspaceInPreferredMainWindow(
        workingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        shouldBringToFront: Bool = false,
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> Workspace? {
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "request",
            source: debugSource,
            reason: "add_workspace",
            event: event,
            chosenContext: nil,
            workingDirectory: workingDirectory
        )
        #endif
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_selection_failed",
                event: event,
                chosenContext: nil,
                workingDirectory: workingDirectory
            )
            #endif
            return nil
        }
        guard let window = resolvedWindow(for: context) else {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "no_context",
                source: debugSource,
                reason: "context_window_missing",
                event: event,
                chosenContext: context,
                workingDirectory: workingDirectory
            )
            #endif
            discardOrphanedMainWindowContext(context)
            return nil
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }

        let workspace: Workspace
        if initialSurface == .browser {
            workspace = context.tabManager.addWorkspace(initialSurface: .browser, select: true)
        } else if workingDirectory != nil || initialTerminalInput != nil {
            workspace = context.tabManager.addWorkspace(
                workingDirectory: workingDirectory,
                initialTerminalInput: initialTerminalInput,
                select: true,
                autoWelcomeIfNeeded: initialTerminalInput == nil
            )
        } else {
            workspace = context.tabManager.addTab(select: true)
        }
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "created",
            source: debugSource,
            reason: "workspace_created",
            event: event,
            chosenContext: context,
            workspaceId: workspace.id,
            workingDirectory: workingDirectory
        )
        #endif
        return workspace
    }

    // Relaxed from `private` to `internal` so the `WorkspaceCreationActionHosting`
    // witnesses in AppDelegate+WorkspaceCreationActionHosting.swift can reach it.
    func preferredMainWindowContextForWorkspaceCreation(
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> RegisteredMainWindow? {
        if let activeManager = tabManager,
           let activeContext = mainWindowContext(for: activeManager),
           resolvedWindow(for: activeContext) == nil {
            discardOrphanedMainWindowContext(activeContext)
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "active_context_window_missing",
                event: event,
                chosenContext: nil
            )
#endif
        }

        if let context = mainWindowContext(forShortcutEvent: event, debugSource: debugSource) {
            return context
        }

        // If a keyboard event identifies a specific window but that context
        // can't be resolved, do not fall back to another window.
        if shortcutEventHasAddressableWindow(event) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_context_required_no_fallback",
                event: event,
                chosenContext: nil
            )
#endif
            return nil
        }

        if let keyWindow = shortcutRoutingKeyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "key_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "main_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        for window in NSApp.orderedWindows where isMainTerminalWindow(window) {
            if let context = contextForMainTerminalWindow(window) {
                #if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: debugSource,
                    reason: "ordered_windows",
                    event: event,
                    chosenContext: context
                )
                #endif
                return context
            }
        }

        pruneWindowlessMainWindowContexts()
        let fallback = registeredMainWindows.first(where: { resolvedWindow(for: $0) != nil })
        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "fallback_first_context",
            event: event,
            chosenContext: fallback
        )
#endif
        return fallback
    }

    private func shortcutEventHasAddressableWindow(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        // NSEvent.windowNumber can be 0 for responder-chain events that are not
        // actually bound to an NSWindow (notably some WebKit key paths).
        return event.window != nil || event.windowNumber > 0
    }

    func mainWindowContext(
        forShortcutEvent event: NSEvent?,
        debugSource: String = "unspecified"
    ) -> RegisteredMainWindow? {
        guard let event else { return nil }

        if let eventWindow = event.window,
           let context = contextForMainTerminalWindow(eventWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

#if DEBUG
        if event.windowNumber > 0,
           let window = debugShortcutRoutingFocusedWindowOverrideForTesting.window,
           window.windowNumber == event.windowNumber,
           let context = contextForMainTerminalWindow(window) {
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "debug_focused_window_number",
                event: event,
                chosenContext: context
            )
            return context
        }
#endif

        if event.windowNumber > 0,
           let numberedWindow = NSApp.window(withWindowNumber: event.windowNumber),
           let context = contextForMainTerminalWindow(numberedWindow) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        if event.windowNumber > 0,
           let context = registeredMainWindows.first(where: { candidate in
               let window = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return window?.windowNumber == event.windowNumber
           }) {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "choose",
                source: debugSource,
                reason: "event_window_number_scan",
                event: event,
                chosenContext: context
            )
            #endif
            return context
        }

        #if DEBUG
        logWorkspaceCreationRouting(
            phase: "choose",
            source: debugSource,
            reason: "event_context_not_found",
            event: event,
            chosenContext: nil
        )
        #endif
        return nil
    }

    func preferredMainWindowContextForShortcutRouting(event: NSEvent) -> RegisteredMainWindow? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.routing") {
            return context
        }

        if shortcutEventHasAddressableWindow(event) {
            if let eventWindow = resolvedShortcutEventWindow(event),
               AuxiliaryWindowRegistry.default.shouldOwnCloseShortcut(eventWindow.identifier?.rawValue) {
                // Auxiliary cmux windows do not own a terminal tab manager. Let them fall back
                // to the active main terminal window so app shortcuts like Close Tab still route.
            } else {
#if DEBUG
                logWorkspaceCreationRouting(
                    phase: "choose",
                    source: "shortcut.routing",
                    reason: "event_context_required_no_fallback",
                    event: event,
                    chosenContext: nil
                )
#endif
                return nil
            }
        }

        if let keyWindow = shortcutRoutingKeyWindow,
           let context = contextForMainTerminalWindow(keyWindow) {
            return context
        }

        if let mainWindow = NSApp.mainWindow,
           let context = contextForMainTerminalWindow(mainWindow) {
            return context
        }

        if let activeManager = tabManager,
           let context = registeredMainWindow(forManager: activeManager) {
            return context
        }

        return registeredMainWindows.first
    }

    @discardableResult
    private func synchronizeShortcutRoutingContext(event: NSEvent) -> Bool {
        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            focusLog.append(
                "shortcut.route reason=no_context_no_fallback eventWin=\(event.windowNumber) keyCode=\(event.keyCode)"
            )
#endif
            return false
        }

        let alreadyActive =
            tabManager === context.tabManager
            && environment.mainWindowRouter.activeSidebarState === sidebarState(for: context)
            && sidebarSelectionState === sidebarSelectionState(for: context)
        if alreadyActive { return true }

        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            environment.mainWindowRouter.activeSidebarState = sidebarState(for: context)
            sidebarSelectionState = sidebarSelectionState(for: context)
            fileExplorerState = fileExplorerState(for: context)
            terminalControl.setActiveTabManager(context.tabManager)
        }

#if DEBUG
        focusLog.append(
            "shortcut.route reason=sync activeTM=\(pointerString(tabManager)) chosen={\(summarizeContextForWorkspaceRouting(context))}"
        )
#endif
        return true
    }

    private func resolvedMainWindowSource(_ window: NSWindow?) -> NSWindow? {
        guard let window else { return nil }
        if isMainTerminalWindow(window) {
            return window
        }
        if let context = contextForMainWindow(window) ?? contextForMainTerminalWindow(window) {
            return resolvedWindow(for: context)
        }
        return nil
    }

    private func positionNewMainWindow(_ window: NSWindow, relativeTo sourceWindow: NSWindow) {
        let sourceFrame = sourceWindow.frame
        let visibleFrame = (sourceWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(sourceFrame) }))?.visibleFrame
        let planner = Self.newWindowCascadePlanner
        switch planner.placement(sourceFrame: sourceFrame, hasResolvableScreen: visibleFrame != nil, windowSize: window.frame.size) {
        case .center:
            window.center()
        case .frame(let candidateFrame):
            window.setFrame(
                SessionWindowFrameResolver.clampFrame(candidateFrame, within: visibleFrame ?? candidateFrame, minWidth: planner.minimumWindowSize.width, minHeight: planner.minimumWindowSize.height),
                display: false
            )
        }
    }

    @discardableResult
    func createMainWindow(
        initialWorkspaceTitle: String? = nil,
        initialWorkingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        sessionWindowSnapshot: SessionWindowSnapshot? = nil,
        preferredWindowId: UUID? = nil,
        shouldActivate: Bool = true,
        sourceWindow preferredSourceWindow: NSWindow? = nil,
        remapClosedPanelHistoryFromSessionSnapshot: Bool = true,
        excludingStableIdentitiesFromSessionSnapshot: Set<UUID> = [],
        restoredSessionSnapshotHandler: (([[UUID: UUID]], TabManager) -> Void)? = nil
    ) -> UUID {
        reserveInitialSocketPathIfNeeded()
        let requestedWindowId = preferredWindowId ?? sessionWindowSnapshot?.windowId
        let windowId = availableWindowIdForNewMainWindow(preferredWindowId: requestedWindowId) ?? UUID()
        let tabManager = TabManager(
            initialWorkspaceTitle: initialWorkspaceTitle,
            initialWorkingDirectory: initialWorkingDirectory,
            initialTerminalInput: initialTerminalInput,
            autoWelcomeIfNeeded: initialTerminalInput == nil,
            closedItemHistory: closedItemHistory
        )
        tabManager.attachAppEnvironment(environment)
        tabManager.windowId = windowId
        if let sessionWindowSnapshot {
            let restoredPanelIdsByWorkspaceIndex = tabManager.restoreSessionSnapshot(
                sessionWindowSnapshot.tabManager,
                remapClosedPanelHistory: remapClosedPanelHistoryFromSessionSnapshot,
                excludingStableIdentities: excludingStableIdentitiesFromSessionSnapshot
            )
            if let configFrames = sessionWindowSnapshot.configFrames {
                windowConfigFrames[windowId] = SessionConfigFrameRing(entries: configFrames)
            }
            if let originalWindowId = sessionWindowSnapshot.windowId,
               originalWindowId != windowId {
                closedItemHistory.remapWorkspaceWindowIds(from: originalWindowId, to: windowId)
                closedItemHistory.flushPendingSaves()
            }
            restoredSessionSnapshotHandler?(restoredPanelIdsByWorkspaceIndex, tabManager)
        }

        let sidebarWidth = sessionWindowSnapshot?.sidebar.width
            .map { SessionPersistencePolicy.sanitizedSidebarWidth($0) }
            ?? SessionPersistencePolicy.defaultSidebarWidth
#if DEBUG
        let initialSidebarIsVisible = ProcessInfo.processInfo.environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_SIDEBAR"] == "1"
            ? false
            : (sessionWindowSnapshot?.sidebar.isVisible ?? true)
#else
        let initialSidebarIsVisible = sessionWindowSnapshot?.sidebar.isVisible ?? true
#endif
        let sidebarState = SidebarState(
            isVisible: initialSidebarIsVisible,
            persistedWidth: CGFloat(sidebarWidth)
        )
        let sidebarSelectionState = SidebarSelectionState(
            selection: sessionWindowSnapshot?.sidebar.selection.sidebarSelection ?? .tabs
        )

        // Seed the per-window Bonsplit tab-bar leading inset before ContentView first
        // renders. The initial workspace is created inside TabManager.init, at which
        // point there is no source workspace or prior window inset to inherit from, so
        // applyCreationChromeInheritance returns early and leaves the Bonsplit inset
        // at 0 — which is wrong in minimal mode with the sidebar collapsed, where the
        // native traffic lights need an 80pt reserved strip on the tab bar. Without
        // this seed, the first-frame layout can mispaint in the new window until
        // ContentView.onAppear eventually runs syncTrafficLightInset (#2737).
        let initialTabBarLeadingInset: CGFloat =
            (WorkspacePresentationModeSettings.isMinimal() && !sidebarState.isVisible)
                ? MinimalModeTitlebarDebugSnapshot.trafficLightTabBarLeadingInset()
                : 0
        tabManager.syncWorkspaceTabBarLeadingInset(initialTabBarLeadingInset)
        let notificationStore = TerminalNotificationStore.shared

        let cmuxConfigStore = CmuxConfigStore()
        cmuxConfigStore.wireDirectoryTracking(tabManager: tabManager)
        cmuxConfigStore.loadAll()

        let fileExplorerState = FileExplorerState()
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] == "1" {
            fileExplorerState.mode = .files
            fileExplorerState.isVisible = true
        }
#endif

        let root = ContentView(updateViewModel: updateViewModel, windowId: windowId)
            .environment(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environment(sidebarState)
            .environment(sidebarSelectionState)
            .environmentObject(fileExplorerState)
            .environmentObject(cmuxConfigStore)
            // AppKit hosts this ContentView in its own NSHostingView, which does
            // not inherit the App scene's SwiftUI environment. Inject the
            // settings runtime so `@LiveSetting` can resolve the stores it
            // observes throughout the main window (e.g. the sidebar). The key is
            // optional, so a nil runtime just leaves reads at their seeded
            // catalog default.
            .environment(\.settingsRuntime, settingsRuntime)
            // Inject the composition-root-owned process-lifetime service holder
            // (Wave 1 of the `AppDelegate.shared` de-singletonization) so views
            // read process services via `@Environment(\.appEnvironment)` instead
            // of the singleton. Nil-default key: a view rendered outside this
            // injected scope short-circuits exactly like `AppDelegate.shared?`.
            .environment(\.appEnvironment, environment)
            // Inject the composition-root-owned cross-window sidebar drag
            // registry so the sidebar's `SidebarDragState` wires to the shared
            // registry by injection instead of an `AppDelegate.shared` lookup.
            .environment(\.sidebarWorkspaceDragRegistry, sidebarWorkspaceDragRegistry)
#if DEBUG
            // Inject the composition-root-owned debug per-window drag-state
            // registry so the sidebar registers/unregisters its live
            // `SidebarDragState` by injection instead of an `AppDelegate.shared`
            // lookup, mirroring the cross-window registry above.
            .environment(\.sidebarDragStateRegistry, sidebarDragStateRegistry)
#endif

        // Use the current key window's size for new windows so Cmd+Shift+N
        // creates a window matching the previous one's dimensions.
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let sourceContext = preferredMainWindowContextForWorkspaceCreation(
            debugSource: "createMainWindow.initialGeometry"
        )
        let sourceWindow = resolvedMainWindowSource(preferredSourceWindow)
            ?? sourceContext.flatMap { resolvedWindow(for: $0) }
        let existingFrame = sourceWindow?.frame
        let sourceWindowIsNativeFullScreen: Bool = {
#if DEBUG
            if let debugCreateMainWindowSourceIsNativeFullScreenOverride {
                return debugCreateMainWindowSourceIsNativeFullScreenOverride
            }
#endif
            return sourceWindow?.styleMask.contains(.fullScreen) == true
        }()
        let shouldTemporarilyDisallowFullScreenTiling =
            sessionWindowSnapshot == nil && sourceWindowIsNativeFullScreen
        let restoredFrame = resolvedWindowFrame(from: sessionWindowSnapshot)
        let persistedGeometryFrame = (restoredFrame == nil && sourceWindow == nil)
            ? resolvedPersistedWindowGeometryFrame()
            : nil
        let initialRect: NSRect
        if restoredFrame == nil, let existingFrame {
            // Convert frame rect to content rect so the new window matches the
            // source window's actual size (frame includes titlebar insets).
            initialRect = NSWindow.contentRect(forFrameRect: existingFrame, styleMask: styleMask)
        } else if let explicitInitialFrame = restoredFrame ?? persistedGeometryFrame {
            initialRect = NSWindow.contentRect(forFrameRect: explicitInitialFrame, styleMask: styleMask)
        } else {
            initialRect = CmuxMainWindow.defaultContentRect(styleMask: styleMask)
        }

        let window = CmuxMainWindow(
            contentRect: initialRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        let minimumWindowSize = CmuxMainWindow.minimumContentSize
        window.minSize = minimumWindowSize
        window.contentMinSize = minimumWindowSize
        window.animationBehavior = .none
        // When creating a new window from an existing native fullscreen window,
        // temporarily opt out of fullscreen tiling so AppKit doesn't place the
        // new window into the active fullscreen Space.
        if shouldTemporarilyDisallowFullScreenTiling {
            window.collectionBehavior.insert(.fullScreenDisallowsTiling)
        }
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // cmux persists and restores main windows itself. Disable AppKit window
        // restoration so the OS cannot resurrect stale duplicate main windows.
        window.isRestorable = false
        configureCmuxMainWindowDragBehavior(window)
        let explicitInitialFrame = restoredFrame ?? persistedGeometryFrame
        if let explicitInitialFrame {
            window.setFrame(explicitInitialFrame, display: false)
        } else if let sourceWindow {
            positionNewMainWindow(window, relativeTo: sourceWindow)
        } else {
            window.center()
            // Cascade using the same algorithm as upstream Ghostty: seed from
            // the window's own top-left on the first call, then advance the
            // cascade point for each subsequent window.
            if registeredMainWindows.count >= 1 {
                lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
            } else {
                lastCascadePoint = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
            }
        }
        window.contentView = MainWindowHostingView(rootView: root)

        // Apply shared window styling.
        attachUpdateAccessory(to: window)
        applyWindowDecorations(to: window)

        // Keep a strong reference so the window isn't deallocated.
        let controller = MainWindowController(window: window)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let manager = self.tabManagerFor(windowId: windowId)
            // An explicit close of the window's LAST remote workspace (a tab/session
            // close) kills its remote session(s) — synced with tmux — even though it
            // also closes the app window. A plain window/quit close leaves the marker
            // unset and falls through to detach below (server stays alive for resume).
            if self.remoteTmuxController.consumeKillSessionsOnWindowClose(windowId: windowId),
               let manager {
                for workspace in manager.tabs where workspace.isRemoteTmuxMirror {
                    self.remoteTmuxController.handleWorkspaceClosed(workspaceId: workspace.id)
                }
            }
            // If this was a dedicated remote-tmux window, detach its host's control
            // connections (no-op when the kill path above already tore them down).
            // A window/quit close only detaches — the remote tmux server stays alive.
            self.remoteTmuxController.handleRemoteWindowClosed(windowId: windowId)
            // Also detach any per-workspace mirrors in this window (covers the
            // socket `remote.tmux.mirror` path into a non-dedicated window), so
            // their pane surfaces / ssh connections don't leak on window close.
            if let manager {
                self.remoteTmuxController.handleWindowWorkspacesClosed(
                    workspaceIds: manager.tabs.map { $0.id }
                )
            }
            self.mainWindowControllers.removeAll(where: { $0 === controller })
        }
        controller.shouldClose = { [weak self] in
            let shouldClose = self?.handleMainTerminalWindowShouldClose() ?? true
            if !shouldClose {
                self?.closedWindowHistorySuppressedWindowIds.remove(windowId)
                // Close CANCELLED (a genuine veto, not a confirmed quit): clear any
                // kill-on-close marker so a later window/quit close detaches. A
                // CONFIRMED quit of the last tab keeps the marker set so
                // applicationWillTerminate kills the session before exit.
                if self?.isTerminatingApp != true {
                    self?.remoteTmuxController.consumeKillSessionsOnWindowClose(windowId: windowId)
                }
            }
            return shouldClose
        }
        window.delegate = controller
        mainWindowControllers.append(controller)

        registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState,
            cmuxConfigStore: cmuxConfigStore
        )
        // Express the per-window association: the controller weakly references the
        // ``WindowContext`` the registration just seeded (the registry stays the
        // strong owner, so this does not extend the context's lifetime).
        controller.windowContext = windowRegistry.context(for: WindowID(windowId))
        publishCmuxWindowLifecycle(name: "window.created", windowId: windowId, origin: "create")
        AppFileDropTarget.installFileDropOverlay(on: window, tabManager: tabManager)
        if !shouldActivate || TerminalController.shouldSuppressSocketCommandActivation() {
            window.orderFront(nil)
            if shouldActivate, TerminalController.socketCommandAllowsInAppFocusMutations() {
                setActiveMainWindow(window)
            }
        } else {
            mainWindowVisibilityController.focus(
                window,
                reason: .createMainWindow,
                activation: .runningApplication([.activateAllWindows]),
                respectActivationSuppression: false
            )
        }
        if shouldTemporarilyDisallowFullScreenTiling {
            let clearFullScreenTilingOptOut: () -> Void = { [weak window] in
                guard let window else { return }
                window.collectionBehavior.remove(.fullScreenDisallowsTiling)
                if window.collectionBehavior.contains(.fullScreenDisallowsTiling) {
                    var behavior = window.collectionBehavior
                    behavior.remove(.fullScreenDisallowsTiling)
                    window.collectionBehavior = behavior
                }
            }
            RunLoop.main.perform {
                clearFullScreenTilingOptOut()
            }
            DispatchQueue.main.async {
                clearFullScreenTilingOptOut()
            }
        }
        if let explicitInitialFrame {
            window.setFrame(explicitInitialFrame, display: true)
#if DEBUG
            cmuxDebugLog(
                "mainWindow.initialFrameApplied source=\(restoredFrame == nil ? "persistedGeometry" : "sessionSnapshot") window=\(windowId.uuidString.prefix(8)) " +
                    "applied={\(SessionRectSnapshot(window.frame).debugLogDescription)}"
            )
#endif
        }
#if DEBUG
        // Honor the shared dev-only default display (set via `cmux window
        // default-display` or the Debug menu) so every dev build, any tag and
        // any launch path, opens on the chosen monitor. Focus-safe and a no-op
        // when unset. See DevWindowDisplayDefault.
        DevWindowDisplayDefault.applyToNewWindow(window)
#endif
        return windowId
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateController.model.setOverrideState(nil)
        updateController.checkForUpdates()
    }

    func checkForUpdatesInCustomUI() {
        updateController.model.setOverrideState(nil)
        updateController.checkForUpdatesInCustomUI()
    }

    func openWelcomeWorkspace() {
        guard let context = preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: "welcome") else {
            return
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }
        let workspace = context.tabManager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
        sendWelcomeCommandWhenReady(to: workspace)
    }

    func sendWelcomeCommandWhenReady(to workspace: Workspace, markShownOnSend: Bool = false) {
        sendTextWhenReady("cmux welcome\n", to: workspace, beforeSend: {
            if markShownOnSend {
                UserDefaults.standard.set(true, forKey: AccountCatalogSection().welcomeShown.userDefaultsKey)
            }
        })
    }

    @objc func applyUpdateIfAvailable(_ sender: Any?) {
        updateController.model.setOverrideState(nil)
        // Main's UpdateController consolidated the force-install path into
        // `attemptUpdate()` (single "install the update" entry point that
        // re-resolves to the latest release first), so both this and the
        // Attempt Update menu action route through it.
        updateController.attemptUpdate()
    }

    @objc func attemptUpdate(_ sender: Any?) {
        updateController.model.setOverrideState(nil)
        updateController.attemptUpdate()
    }

    func isCmuxCLIInstalledInPATH() -> Bool {
        CmuxCLIPathInstaller().isInstalled()
    }

    @objc func installCmuxCLIInPath(_ sender: Any?) {
        let installer = CmuxCLIPathInstaller()
        do {
            let outcome = try installer.install()
            var informativeText = String(localized: "cli.install.symlinkCreated", defaultValue: "Created symlink:\n\n\(outcome.destinationURL.path) -> \(outcome.sourceURL.path)")
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.install.adminRequired", defaultValue: "Administrator privileges were required to write to /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.installed", defaultValue: "cmux CLI Installed"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.installFailed", defaultValue: "Couldn't Install cmux CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    @objc func uninstallCmuxCLIInPath(_ sender: Any?) {
        let installer = CmuxCLIPathInstaller()
        do {
            let outcome = try installer.uninstall()
            let prefix = outcome.removedExistingEntry
                ? String(localized: "cli.uninstall.removed", defaultValue: "Removed \(outcome.destinationURL.path).")
                : String(localized: "cli.uninstall.notFound", defaultValue: "No cmux CLI symlink was found at \(outcome.destinationURL.path).")
            var informativeText = prefix
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.uninstall.adminRequired", defaultValue: "Administrator privileges were required to modify /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.uninstalled", defaultValue: "cmux CLI Uninstalled"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.uninstallFailed", defaultValue: "Couldn't Uninstall cmux CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func presentCLIPathAlert(
        title: String,
        informativeText: String,
        style: NSAlert.Style
    ) {
        CmuxCLIPathAlertPresenter(
            anchorWindowProvider: { NSApp.keyWindow ?? NSApp.mainWindow },
            okButtonTitle: String(localized: "common.ok", defaultValue: "OK")
        )
        .present(title: title, informativeText: informativeText, style: style)
    }

    @objc func restartSocketListener(_ sender: Any?) {
        guard tabManager != nil else {
            NSSound.beep()
            return
        }

        guard socketListenerConfigurationIfEnabled() != nil else {
            terminalControl.stop()
            NSSound.beep()
            return
        }
        restartSocketListenerIfEnabled(source: "menu.command")
    }

    func toggleGlobalSearchPaletteFromGlobalHotkey() {
        menuBarExtraCoordinator.toggleGlobalSearchPaletteFromGlobalHotkey()
    }

    private func installMobileHostSettingsObserver() {
        guard mobileHostSettingsObserver == nil else { return }
        mobileHostSettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMobileHostService()
            }
        }
    }

    private func syncMobileHostService() {
        MobileHostService.shared.syncToSettings()
    }

    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        showFallbackSettingsWindow: @MainActor (SettingsNavigationTarget?) -> Void = { target in
            SettingsWindowPresenter.show(navigationTarget: target)
        },
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        }
    ) {
#if DEBUG
        cmuxDebugLog("settings.open.present path=swiftuiWindow")
#endif
        showFallbackSettingsWindow(navigationTarget)
        activateApplication()
#if DEBUG
        cmuxDebugLog("settings.open.present activate=1")
#endif
    }

    @MainActor
    func openPreferencesWindow(debugSource: String, navigationTarget: SettingsNavigationTarget? = nil) {
#if DEBUG
        cmuxDebugLog("settings.open.request source=\(debugSource)")
#endif
        Self.presentPreferencesWindow(navigationTarget: navigationTarget)
    }

    @objc func openPreferencesWindow() {
        openPreferencesWindow(debugSource: "appDelegate")
    }

    func refreshMenuBarExtraForDebug() {
        menuBarExtraCoordinator.refreshMenuBarExtraForDebug()
    }

    func openTaskManagerWindow() {
        TaskManagerWindowController.shared.show()
    }

    func captureMainWindowVisibilityRestoreTargetsForApplicationHide() {
        mainWindowVisibilityController.captureHiddenWindowRestoreTargets(windows: mainWindowsForVisibilityController())
    }

    func dismissMainWindowFromWindowChrome(_ window: NSWindow) {
        mainWindowVisibilityController.dismissWindows(windows: [window], reason: .titlebarDismiss)
    }

    func toggleApplicationVisibilityFromGlobalHotkey() {
        mainWindowVisibilityController.toggleApplicationVisibility(
            windows: mainWindowsForVisibilityController(),
            reason: .globalHotkey
        )
    }

    @discardableResult
    func activateMainWindowFromSocket() -> Bool {
        let window = preferredMainWindowForVisibilityActivation() ?? {
            let windowId = ensureInitialMainWindowIfNeeded(shouldActivate: false)
            return windowForMainWindowId(windowId)
        }()
        guard let window else { return false }
        return mainWindowVisibilityController.focus(
            window,
            reason: .socketActivate,
            activation: .runningApplication([.activateAllWindows]),
            respectActivationSuppression: false
        )
    }

    @discardableResult
    func focusWindowForAppActivation(
        _ window: NSWindow,
        reason: MainWindowVisibilityController.Reason
    ) -> Bool {
        mainWindowVisibilityController.focus(
            window,
            reason: reason,
            activation: .runningApplication([.activateAllWindows]),
            respectActivationSuppression: false
        )
    }

    /// Builds the window-domain ``MainWindowActivationResolver`` from the live
    /// AppKit/window-context sources. The selection/ordering policy lives in
    /// `CmuxWindowing`; this factory binds it to the app's live state.
    private func makeMainWindowActivationResolver() -> MainWindowActivationResolver {
        MainWindowActivationResolver(
            sortedContextWindows: { [weak self] in
                guard let self else { return [] }
                return self.sortedMainWindowContextsForSessionSnapshot()
                    .compactMap { self.resolvedWindow(for: $0) }
            },
            keyWindow: { NSApp.keyWindow },
            mainWindow: { NSApp.mainWindow },
            allWindows: { NSApp.windows },
            isMainTerminalWindow: { [weak self] window in
                self?.isMainTerminalWindow(window) ?? false
            },
            isVisible: { $0.isVisible },
            isMiniaturized: { $0.isMiniaturized }
        )
    }

    private func preferredMainWindowForVisibilityActivation() -> NSWindow? {
        makeMainWindowActivationResolver().preferredMainWindowForVisibilityActivation()
    }

    @MainActor
    func preferredMainWindowForSettingsPresentation() -> NSWindow? {
        preferredMainWindowForVisibilityActivation()
    }

    @discardableResult func showMainWindowFromMenuBar() -> NSWindow? {
        if let window = mainWindowVisibilityController.showApplicationWindows(
            windows: mainWindowsForVisibilityController(),
            reason: .menuBar
        ) {
            return window
        }

        let windowId = ensureInitialMainWindowIfNeeded(shouldActivate: false)
        guard let window = windowForMainWindowId(windowId) else {
            NSSound.beep()
            return nil
        }
        _ = mainWindowVisibilityController.focus(
            window,
            reason: .menuBar,
            respectActivationSuppression: false
        )
        return window
    }

    // Internal (not private) so the `ApplicationActivationHost` conformance in
    // `AppDelegate+ApplicationActivationHost.swift` can witness the activation
    // visibility methods.
    func mainWindowsForVisibilityController() -> [NSWindow] {
        makeMainWindowActivationResolver().mainWindowsForVisibilityController()
    }

    /// Forwards to `notificationNavigation` (the extracted
    /// `NotificationNavigationCoordinator`). The coordinator sequences the
    /// surface-window-then-present flow; the window resolve-or-create,
    /// `bringToFront`, and the delayed `NSPopover` present stay here behind
    /// `NotificationPopoverPresenting` (reached via `NotificationNavSeamAdapter`)
    /// because they read late-bound `NSWindow`/`NSApp` state and drive the
    /// app-side titlebar accessory controller. Behavior is byte-identical.
    func showNotificationsPopoverFromMenuBar() {
        notificationNavigation.showNotificationsPopoverFromMenuBar()
    }

    /// Surfaces (or creates) and brings to front the main window that should host
    /// the menu-bar notifications popover. Lifted from the first phase of the
    /// legacy `showNotificationsPopoverFromMenuBar()`; kept on `AppDelegate` so it
    /// retains access to the live window-context registry and `NSApp`.
    func surfaceWindowForMenuBarNotificationsPopover() {
        let context: RegisteredMainWindow? = {
            if let keyWindow = NSApp.keyWindow,
               let keyContext = contextForMainTerminalWindow(keyWindow) {
                return keyContext
            }
            if let first = registeredMainWindows.first {
                return first
            }
            let windowId = createMainWindow()
            return registeredMainWindow(forWindowId: windowId)
        }()

        if let context,
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }
    }

    /// Presents the notifications popover from the menu bar. Lifted from the final
    /// phase of the legacy `showNotificationsPopoverFromMenuBar()`; the
    /// `asyncAfter` present delay is an AppKit timing side effect preserved
    /// byte-identically (it must stay app-side, not in package code).
    func presentMenuBarNotificationsPopover() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.titlebarAccessoryController.showNotificationsPopover(animated: false)
        }
    }

    #if DEBUG
    @objc func showUpdatePill(_ sender: Any?) {
        updateController.model.debugShowInstallingPill()
    }

    @objc func showUpdatePillLongNightly(_ sender: Any?) {
        updateController.model.debugShowLongNightlyPill()
    }

    @objc func showUpdatePillLoading(_ sender: Any?) {
        updateController.model.debugShowCheckingPill()
    }

    @objc func hideUpdatePill(_ sender: Any?) {
        updateController.model.debugHidePill()
    }

    @objc func clearUpdatePillOverride(_ sender: Any?) {
        updateController.model.debugClearPillOverride()
    }
#endif

    @objc func copyUpdateLogs(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(environment.updateLog.clipboardPayload(), forType: .string)
    }
    @objc func copyFocusLogs(_ sender: Any?) {
        let logText = focusLog.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No focus logs captured.\nLog file: \(focusLog.logPath())"
        } else {
            payload = logText + "\nLog file: \(focusLog.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }

    /// Forwards a Feed-layer focus request to the extracted ``FeedRequestRouter``.
    /// The `@objc` selector signature and `userInfo` parsing stay app-side
    /// (selectors cannot move into a package, and `userInfo` is `[AnyHashable: Any]`);
    /// the router builds the V2 socket commands and routes them through the
    /// in-process handler, byte-identical to the former inline body.
    @objc private func handleFeedRequestFocus(_ notification: Notification) {
        guard let workspaceId = notification.userInfo?["workspaceId"] as? String,
              let surfaceId = notification.userInfo?["surfaceId"] as? String
        else { return }
        feedRequestRouter.routeFocus(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    /// Forwards a Feed-layer send-text request to the extracted ``FeedRequestRouter``.
    /// See ``handleFeedRequestFocus(_:)`` for why the selector and `userInfo`
    /// parsing remain app-side. The router appends the terminal-mode CR.
    @objc private func handleFeedRequestSendText(_ notification: Notification) {
        guard let surfaceId = notification.userInfo?["surfaceId"] as? String,
              let text = notification.userInfo?["text"] as? String,
              !text.isEmpty
        else { return }
        feedRequestRouter.routeSendText(surfaceId: surfaceId, text: text)
    }

    @objc private func handleReactGrabDidCopySelection(_ notification: Notification) {
        let browserPanelId = notification.userInfo?[ReactGrabPastebackNotificationKey.browserPanelId] as? UUID
        guard let workspaceId = notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID,
              let returnPanelId = notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID,
              let content = notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String else {
#if DEBUG
            cmuxDebugLog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingNotificationFields " +
                "workspace=\(Self.debugShortId(notification.userInfo?[ReactGrabPastebackNotificationKey.workspaceId] as? UUID)) " +
                "browser=\(Self.debugShortId(browserPanelId)) " +
                "return=\(Self.debugShortId(notification.userInfo?[ReactGrabPastebackNotificationKey.returnPanelId] as? UUID)) " +
                "hasContent=\((notification.userInfo?[ReactGrabPastebackNotificationKey.content] as? String) != nil ? 1 : 0)"
            )
#endif
            return
        }

        guard let manager = tabManagerFor(tabId: workspaceId),
              let workspace = manager.tabs.first(where: { $0.id == workspaceId }) else {
#if DEBUG
            cmuxDebugLog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingWorkspace workspace=\(Self.debugShortId(workspaceId)) " +
                "browser=\(Self.debugShortId(browserPanelId)) return=\(Self.debugShortId(returnPanelId))"
            )
#endif
            return
        }

        guard workspace.terminalPanel(for: returnPanelId) != nil else {
#if DEBUG
            cmuxDebugLog(
                "reactGrab.pasteback h3.didCopy.drop " +
                "reason=missingReturnTerminal workspace=\(Self.debugShortId(workspaceId)) " +
                "browser=\(Self.debugShortId(browserPanelId)) return=\(Self.debugShortId(returnPanelId)) " +
                "focused=\(Self.debugShortId(workspace.focusedPanelId))"
            )
#endif
            return
        }

#if DEBUG
        cmuxDebugLog(
            "reactGrab.pasteback h3.didCopy " +
            "workspace=\(Self.debugShortId(workspaceId)) " +
            "browser=\(Self.debugShortId(browserPanelId)) " +
            "return=\(Self.debugShortId(returnPanelId)) " +
            "focusedBefore=\(Self.debugShortId(workspace.focusedPanelId)) len=\(content.count)"
        )
#endif
        manager.focusTab(workspaceId, surfaceId: returnPanelId, suppressFlash: true)
#if DEBUG
        cmuxDebugLog(
            "reactGrab.pasteback h1.focusRequested " +
            "workspace=\(Self.debugShortId(workspaceId)) " +
            "return=\(Self.debugShortId(returnPanelId)) " +
            "focusedAfterRequest=\(Self.debugShortId(workspace.focusedPanelId))"
        )
#endif
        sendTextWhenReady(content, to: workspace, preferredPanelId: returnPanelId)
    }

    nonisolated private static func debugShortId(_ id: UUID?) -> String {
        id.map { String($0.uuidString.prefix(5)) } ?? "nil"
    }

    static func resolveTerminalPanelForTextSend(in tab: Tab, preferredPanelId: UUID? = nil) -> TerminalPanel? {
        if let preferredPanelId {
            return tab.terminalPanel(for: preferredPanelId)
        }
        return tab.focusedTerminalPanel
    }

    /// Delivers `text` to `tab`'s terminal once a surface is ready (3s timeout).
    ///
    /// The readiness orchestration (resolution precedence, the resolved latch,
    /// the surface-match gating, observer lifecycle, the timeout) lives in
    /// ``TerminalTextSendCoordinator`` in `CmuxNotifications`. This shim builds the
    /// app-side `TerminalTextSendTargetAdapter` (wrapping `Workspace.panelsPublisher`,
    /// the ghostty `NotificationCenter` readiness signals, and the `asyncAfter`
    /// timeout) and, in DEBUG reactGrab pasteback flows, the
    /// `TerminalTextSendTracer` that emits the identical `cmuxDebugLog` lines, then
    /// forwards. Byte-identical to the former inline body.
    func sendTextWhenReady(
        _ text: String,
        to tab: Tab,
        preferredPanelId: UUID? = nil,
        beforeSend: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        var tracing: (any TerminalTextSendTracing)?
#if DEBUG
        if preferredPanelId != nil {
            tracing = TerminalTextSendTracer(tab: tab)
        }
#endif
        let coordinator = TerminalTextSendCoordinator(tracing: tracing)
        coordinator.send(
            text,
            to: TerminalTextSendTargetAdapter(tab),
            preferredPanelID: preferredPanelId,
            beforeSend: beforeSend,
            onFailure: onFailure
        )
    }

#if DEBUG
    // Read by `logSlowShortcutMonitorLatencyIfNeeded` here and set by the
    // `DebugStressWorkspaceHosting` conformance in a sibling file; `internal`
    // so the cross-file extension can flip it on at batch start.
    var debugStressLagProbeEnabled = false

    /// Orchestrates the DEBUG stress-workspace harness. The driver owns the
    /// creation loop, timing, and logging; this app delegate conforms
    /// ``DebugStressWorkspaceHosting`` and supplies the live workspace / window /
    /// terminal-surface operations.
    private lazy var debugStressWorkspaceDriver = DebugStressWorkspaceDriver(host: self)

    /// Orchestrates the Debug menu's terminal-tab openers (scrollback / lorem /
    /// agent-session / color-comparison). The coordinator owns each opener's
    /// logic; this app delegate conforms ``DebugTerminalActionsHosting`` (in a
    /// sibling file) and supplies the live tab / workspace / terminal-surface
    /// operations. The `@objc` selector methods below stay here as one-line
    /// forwarders so NSMenu target-action keeps resolving on the app delegate.
    private lazy var debugTerminalActionsCoordinator = DebugTerminalActionsCoordinator(host: self)

    /// The live objects backing one queued stress surface, the former
    /// `DebugStressTerminalLoadTarget`. Kept app-side because it names
    /// `Workspace`/`PaneID`/`TabID`, which cannot cross the package boundary.
    struct DebugStressTerminalLoadTarget {
        let workspace: Workspace
        let paneId: PaneID
        let tabId: TabID
        let panelId: UUID
    }

    /// Transient map from a driver-issued ``DebugStressLoadTargetHandle`` raw
    /// value to its live target, populated for the duration of one harness run.
    var debugStressLoadTargets: [UUID: DebugStressTerminalLoadTarget] = [:]

    @objc func openDebugScrollbackTab(_ sender: Any?) {
        debugTerminalActionsCoordinator.openScrollbackTab()
    }

    @objc func openDebugLoremTab(_ sender: Any?) {
        debugTerminalActionsCoordinator.openLoremTab()
    }

    @objc func openDebugAgentSessionReact(_ sender: Any?) {
        debugTerminalActionsCoordinator.openAgentSession(rendererKind: .react)
    }

    @objc func openDebugAgentSessionSolid(_ sender: Any?) {
        debugTerminalActionsCoordinator.openAgentSession(rendererKind: .solid)
    }

    @objc func openDebugColorComparisonWorkspaces(_ sender: Any?) {
        debugTerminalActionsCoordinator.openColorComparisonWorkspaces()
    }

    @objc func openDebugStressWorkspacesWithLoadedSurfaces(_ sender: Any?) {
        debugStressWorkspaceDriver.openStressWorkspacesWithLoadedSurfaces()
    }

    private func debugStressLagSnapshot() -> (
        workspaceCount: Int,
        terminalPanelCount: Int,
        loadedSurfaceCount: Int,
        selectedWorkspace: String
    ) {
        guard let tabManager else {
            return (0, 0, 0, "nil")
        }
        var terminalPanelCount = 0
        var loadedSurfaceCount = 0
        for workspace in tabManager.tabs {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                terminalPanelCount += 1
                if terminalPanel.surface.surface != nil {
                    loadedSurfaceCount += 1
                }
            }
        }
        let selectedWorkspace = tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        return (
            tabManager.tabs.count,
            terminalPanelCount,
            loadedSurfaceCount,
            selectedWorkspace
        )
    }

    private func logSlowShortcutMonitorLatencyIfNeeded(
        event: NSEvent,
        handledByShortcut: Bool,
        elapsedMs: Double
    ) {
        guard debugStressLagProbeEnabled else { return }
        guard event.type == .keyDown else { return }

        let normalizedFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainTyping = normalizedFlags.isDisjoint(with: [.command, .control, .option])
        let thresholdMs: Double = event.isARepeat ? 1.5 : (isPlainTyping ? 2.5 : 6.0)
        guard elapsedMs >= thresholdMs else { return }

        let snapshot = debugStressLagSnapshot()
        cmuxDebugLog(
            "stress.inputLag path=appMonitor ms=\(String(format: "%.2f", elapsedMs)) " +
            "threshold=\(String(format: "%.2f", thresholdMs)) handled=\(handledByShortcut ? 1 : 0) " +
            "plain=\(isPlainTyping ? 1 : 0) repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) " +
            "mods=\(event.modifierFlags.rawValue) workspaces=\(snapshot.workspaceCount) " +
            "terminals=\(snapshot.terminalPanelCount) surfacesReady=\(snapshot.loadedSurfaceCount) " +
            "selected=\(snapshot.selectedWorkspace)"
        )
    }

    @objc func triggerSentryTestCrash(_ sender: Any?) {
        SentrySDK.crash()
    }
#endif

#if DEBUG
    /// Live notification-open hook: records jump-unread open-routing keys to the
    /// shared jump-unread capture file. The notification-open routing lives in
    /// `AppDelegate` (it needs live window/context state), so it writes through
    /// ``JumpUnreadUITestRecorder``'s single capture-file writer.
    func writeJumpUnreadTestData(_ updates: [String: String]) {
        let recorder = jumpUnreadUITestRecorder ?? JumpUnreadUITestRecorder(appDelegate: self)
        jumpUnreadUITestRecorder = recorder
        recorder.writeData(updates)
    }

    /// Live first-responder hook: arms the jump-to-unread focus expectation.
    /// Forwards to ``JumpUnreadUITestRecorder``.
    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let recorder = jumpUnreadUITestRecorder ?? JumpUnreadUITestRecorder(appDelegate: self)
        jumpUnreadUITestRecorder = recorder
        recorder.armFocusRecord(tabId: tabId, surfaceId: surfaceId)
    }

    /// Live first-responder hook: records the jump-to-unread focus when it
    /// matches the armed expectation. Forwards to ``JumpUnreadUITestRecorder``.
    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        jumpUnreadUITestRecorder?.recordFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
    }

    private func setupTerminalViewportUITestIfNeeded() {
        guard !didSetupTerminalViewportUITest else { return }
        let env = ProcessInfo.processInfo.environment
        guard TerminalViewportUITestRecorder.isEnabled(environment: env) else { return }
        didSetupTerminalViewportUITest = true

        terminalViewportUITestRecorder?.stop()
        terminalViewportUITestRecorder = TerminalViewportUITestRecorder(
            environment: env,
            contextProvider: { [weak self] in
                guard let self else { return [] }
                return Array(self.registeredMainWindows)
            },
            sidebarStateProvider: { [weak self] context in
                guard let self else { return SidebarState() }
                return self.sidebarState(for: context)
            },
            fileExplorerStateProvider: { [weak self] context in
                guard let self else { return nil }
                return self.fileExplorerState(for: context)
            }
        )
        terminalViewportUITestRecorder?.start()
    }

    /// Live navigation hook: forwards a goto-split focus move to
    /// ``GotoSplitUITestRecorder``.
    private func recordGotoSplitMoveIfNeeded(direction: NavigationDirection) {
        gotoSplitUITestRecorder?.recordMoveIfNeeded(direction: direction)
    }

    /// Live navigation hook: forwards a goto-split pane split to
    /// ``GotoSplitUITestRecorder``.
    private func recordGotoSplitSplitIfNeeded(direction: SplitDirection) {
        gotoSplitUITestRecorder?.recordSplitIfNeeded(direction: direction)
    }

    /// Live navigation hook: forwards a split-zoom toggle to
    /// ``GotoSplitUITestRecorder``.
    private func recordGotoSplitZoomIfNeeded(tabManager: TabManager? = nil) {
        gotoSplitUITestRecorder?.recordZoomIfNeeded(tabManager: tabManager)
    }

    /// Installs the ``MultiWindowNotificationUITestScaffold`` once; the scaffold
    /// owns the second-window creation, notification seeding, source-terminal
    /// focusing, control-socket probing, and byte-faithful capture-file writes.
    /// It carries its own one-shot guard, so this is safe to call
    /// unconditionally during launch.
    private func setupMultiWindowNotificationsUITestIfNeeded() {
        let scaffold = multiWindowNotificationUITestScaffold
            ?? MultiWindowNotificationUITestScaffold(appDelegate: self)
        multiWindowNotificationUITestScaffold = scaffold
        scaffold.installIfNeeded()
    }

    // Internal (not private) so the DEBUG `MultiWindowNotificationUITestScaffold`
    // can drive the window-route CLI step once the socket is ready. This stays in
    // the app target because it owns the `MultiWindowRouter` /
    // `MultiWindowWindowRouteCoordinator` and the control socket.
    func runMultiWindowWindowRouteCLIIfNeeded(
        at path: String,
        window1Id: UUID,
        window2Id: UUID,
        socketPath: String
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_WINDOW_ROUTE_CLI"] == "1" else { return }
        let currentStatus = loadMultiWindowNotificationTestData(at: path)["windowRouteStatus"] ?? ""
        guard currentStatus.isEmpty else { return }

        let title = env["CMUX_UI_TEST_WINDOW_ROUTE_CLI_TITLE"] ?? "window-route-\(UUID().uuidString.prefix(8))"
        writeMultiWindowNotificationTestData([
            "windowRouteTitle": title,
            "windowRouteStatus": "pending",
            "windowRouteFailure": "",
        ], at: path)

        guard let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            writeMultiWindowNotificationTestData([
                "windowRouteStatus": "0",
                "windowRouteFailure": "missing_cli",
            ], at: path)
            return
        }

        let processEnv = env.merging([
            "CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC": "6",
        ]) { _, new in new }

        let health = terminalControl.socketListenerHealth(expectedSocketPath: socketPath)
        guard health.socketPathExists else {
            writeMultiWindowNotificationTestData([
                "windowRouteStatus": "0",
                "windowRouteFailure": "socket_not_ready",
            ], at: path)
            return
        }

        let coordinator = MultiWindowWindowRouteCoordinator(
            router: MultiWindowRouter(
                cliURL: cliURL,
                socketPath: socketPath,
                environment: processEnv
            )
        )
        // Inherits MainActor; each await runs the CLI off-main and the final
        // write lands back on main, matching the legacy queue hops.
        Task(priority: .userInitiated) { [weak self] in
            let outcome = await coordinator.routeWindowWorkspace(
                title: title,
                window1Id: window1Id,
                window2Id: window2Id
            )

            self?.writeMultiWindowNotificationTestData([
                "windowRouteStatus": "1",
                "windowRouteCreateStatus": String(outcome.create.terminationStatus),
                "windowRouteCreateStdout": outcome.create.stdout,
                "windowRouteCreateStderr": outcome.create.stderr,
                "windowRouteWindow2Status": String(outcome.window2List.terminationStatus),
                "windowRouteWindow2Stdout": outcome.window2List.stdout,
                "windowRouteWindow2Stderr": outcome.window2List.stderr,
                "windowRouteWindow1Status": String(outcome.window1List.terminationStatus),
                "windowRouteWindow1Stdout": outcome.window1List.stdout,
                "windowRouteWindow1Stderr": outcome.window1List.stderr,
            ], at: path)
        }
    }

    /// Merges `updates` into the multi-window notification capture file at
    /// `path`. The byte-faithful unsorted-keys merge/load/write lives in
    /// ``UITestKeyValueCaptureFile``; this shim only resolves the live path the
    /// app-coupled harness orchestration computed.
    private func writeMultiWindowNotificationTestData(_ updates: [String: String], at path: String) {
        UITestKeyValueCaptureFile(path: path).merge(updates)
    }

    /// Reads the multi-window notification capture file at `path`, returning
    /// `[:]` for an absent or unparsable file. Forwards to
    /// ``UITestKeyValueCaptureFile``.
    private func loadMultiWindowNotificationTestData(at path: String) -> [String: String] {
        UITestKeyValueCaptureFile(path: path).load()
    }

    /// Forwards the multi-window notification focus record to the
    /// ``MultiWindowNotificationUITestScaffold`` (the env-gated capture-file
    /// writer that owns this scenario), creating it lazily if a notification
    /// open fires before setup ran.
    func recordMultiWindowNotificationFocusIfNeeded(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        sidebarSelection: SidebarSelection
    ) {
        let scaffold = multiWindowNotificationUITestScaffold
            ?? MultiWindowNotificationUITestScaffold(appDelegate: self)
        multiWindowNotificationUITestScaffold = scaffold
        scaffold.recordFocusIfNeeded(
            windowId: windowId,
            tabId: tabId,
            surfaceId: surfaceId,
            sidebarSelection: sidebarSelection
        )
    }
#endif

    func attachUpdateAccessory(to window: NSWindow) {
        titlebarAccessoryController.start()
        titlebarAccessoryController.attach(to: window)
    }

    // Satisfies CmuxAppKitSupportUI's WindowDecorating seam (see extension below).
    func applyWindowDecorations(to window: NSWindow) {
        windowDecorationsController.apply(to: window)
    }

    func toggleNotificationsPopover(animated: Bool = true, anchorView: NSView? = nil) {
        titlebarAccessoryController.toggleNotificationsPopover(animated: animated, anchorView: anchorView)
    }

    @discardableResult
    func dismissNotificationsPopoverIfShown() -> Bool {
        titlebarAccessoryController.dismissNotificationsPopoverIfShown()
    }

    func isNotificationsPopoverShown() -> Bool {
        titlebarAccessoryController.isNotificationsPopoverShown()
    }

    /// Forwards to `notificationNavigation` (the extracted
    /// `NotificationNavigationCoordinator`). The nil-store guard and the
    /// `#if DEBUG` UI-test recorder stay here because they read app-target state
    /// (`notificationStore`, the env-gated test sink). The coordinator returns
    /// the opened notification's id, which we re-resolve to the current store
    /// snapshot exactly as the legacy body did.
    @discardableResult
    func jumpToLatestUnread(
        excludingNotificationId excludedNotificationId: UUID? = nil,
        excludingWorkspaceId excludedWorkspaceId: UUID? = nil
    ) -> TerminalNotification? {
        guard let notificationStore else { return nil }
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData([
                "jumpUnreadInvoked": "1",
                "jumpUnreadNotificationCount": String(notificationStore.notifications.count),
            ])
        }
#endif
        guard let openedId = notificationNavigation.jumpToLatestUnread(
            excludingNotificationId: excludedNotificationId,
            excludingWorkspaceId: excludedWorkspaceId
        ) else {
            return nil
        }
        return notificationStore.notifications.first(where: { $0.id == openedId })
    }

    /// Forwards to `notificationNavigation` (the extracted
    /// `NotificationNavigationCoordinator` and its `FocusedNotificationMarker`).
    /// The state machine and its workspace/store predicates now live in
    /// `CmuxNotifications`, reached through the `FocusedNotificationResolving`
    /// seam (see `AppDelegate+NotificationNavSeams.swift`). `preferredWindow` is
    /// passed through as the opaque resolver token.
    @discardableResult
    func toggleFocusedNotificationUnread(
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        notificationNavigation.toggleFocusedNotificationUnread(preferredWindowToken: preferredWindow)
    }

    /// Forwards to `notificationNavigation`. The marker returns the opened
    /// notification id, which we re-resolve to the current store snapshot
    /// exactly as the legacy body did via `jumpToLatestUnread`.
    @discardableResult
    func markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
        preferredWindow: NSWindow? = nil
    ) -> TerminalNotification? {
        guard let openedId = notificationNavigation
            .markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(preferredWindowToken: preferredWindow) else {
            return nil
        }
        return notificationStore?.notifications.first(where: { $0.id == openedId })
    }

    static func installWindowResponderSwizzlesForTesting() {
        _ = didInstallApplicationAccessibilitySwizzle
        _ = didInstallApplicationSendActionSwizzle
        _ = didInstallApplicationSendEventSwizzle
        _ = didInstallWindowKeyEquivalentSwizzle
        _ = didInstallWindowFirstResponderSwizzle
        _ = didInstallWindowSendEventSwizzle
#if DEBUG
        installShortcutRoutingFocusedWindowSwizzleForTesting()
#endif
    }

#if DEBUG
    static func setWindowFirstResponderGuardTesting(currentEvent: NSEvent?, hitView: NSView?) {
        cmuxFirstResponderGuardCurrentEventOverride = currentEvent
        cmuxFirstResponderGuardHitViewOverride = hitView
    }

    static func clearWindowFirstResponderGuardTesting() {
        cmuxFirstResponderGuardCurrentEventOverride = nil
        cmuxFirstResponderGuardHitViewOverride = nil
    }
#endif

    private func installWindowResponderSwizzles() {
        _ = Self.didInstallApplicationAccessibilitySwizzle
        _ = Self.didInstallApplicationSendActionSwizzle
        _ = Self.didInstallApplicationSendEventSwizzle
        _ = Self.didInstallWindowKeyEquivalentSwizzle
        _ = Self.didInstallWindowFirstResponderSwizzle
        _ = Self.didInstallWindowSendEventSwizzle
    }

    private func installShortcutMonitor() {
        // Local monitor only receives events when app is active (not global)
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]
        ) { [weak self] event in
            guard let self else { return event }
            if ShortcutRecorderEventRouter.dispatchActiveRecordingEvent(
                event,
                preferredWindow: event.window ?? shortcutRoutingActiveWindow
            ) {
                return nil
            }
            if event.type == .systemDefined {
                return event
            }
            if event.type == .keyDown {
#if DEBUG
                let phaseTotalStart = ProcessInfo.processInfo.systemUptime
                let preludeStart = ProcessInfo.processInfo.systemUptime
                var preludeMs: Double = 0
                var shortcutMs: Double = 0
                CmuxTypingTiming.logEventDelay(path: "appMonitor", event: event)
                let shortcutMonitorTraceEnabled =
                    ProcessInfo.processInfo.environment["CMUX_SHORTCUT_MONITOR_TRACE"] == "1"
                    || UserDefaults.standard.bool(forKey: "cmuxShortcutMonitorTrace")
                if shortcutMonitorTraceEnabled {
                    let frType = shortcutRoutingKeyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    cmuxDebugLog(
                        "monitor.keyDown: \(event.cmuxKeyDescription) fr=\(frType) addrBarId=\(self.browserOmnibarFocusTracker.focusedPanelId?.uuidString.prefix(8) ?? "nil") \(self.debugShortcutRouteSnapshot(event: event))"
                    )
                }
                if let probeKind = self.developerToolsShortcutProbeKind(event: event) {
                    self.logDeveloperToolsShortcutSnapshot(phase: "monitor.pre.\(probeKind)", event: event)
                }
                preludeMs = (ProcessInfo.processInfo.systemUptime - preludeStart) * 1000.0
                let shortcutTimingStart = CmuxTypingTiming.start()
#endif
                let shortcutStart = ProcessInfo.processInfo.systemUptime
                let handledByShortcut = cmuxCloseFocusedTerminalFindForEscape(event: event, appDelegate: self)
                    || self.handleCustomShortcut(event: event)
#if DEBUG
                shortcutMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                CmuxTypingTiming.logDuration(
                    path: "appMonitor.handleCustomShortcut",
                    startedAt: shortcutTimingStart,
                    event: event,
                    extra: "handled=\(handledByShortcut ? 1 : 0)"
                )
                let shortcutElapsedMs = (ProcessInfo.processInfo.systemUptime - shortcutStart) * 1000.0
                self.logSlowShortcutMonitorLatencyIfNeeded(
                    event: event,
                    handledByShortcut: handledByShortcut,
                    elapsedMs: shortcutElapsedMs
                )
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "appMonitor.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 0.75,
                    parts: [
                        ("preludeMs", preludeMs),
                        ("shortcutMs", shortcutMs),
                    ],
                    extra: "handled=\(handledByShortcut ? 1 : 0)"
                )
#endif
                if handledByShortcut {
#if DEBUG
                    cmuxDebugLog("  → consumed by handleCustomShortcut")
#endif
                    return nil // Consume the event
                }
                return event // Pass through
            }
            self.handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
            if self.clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true) {
                return nil
            }
            return event
        }
    }

    private func installShortcutDefaultsObserver() {
        guard shortcutDefaultsObserver == nil else { return }
        shortcutDefaultsObserver = NotificationCenter.default.addObserver(
            forName: KeyboardShortcutSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleShortcutDefaultsDidChange()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleShortcutDefaultsDidChange()
                }
            }
        }
    }

    private func handleShortcutDefaultsDidChange() {
        clearConfiguredShortcutChordState()
        scheduleReloadConfigurationMenuItemRefresh()
        scheduleSplitButtonTooltipRefreshAcrossWorkspaces()
    }

    private func currentConfiguredShortcutChordActions() -> [KeyboardShortcutSettings.Action] {
        KeyboardShortcutSettings.Action.allCases.filter { action in
            // System-wide hotkeys are dispatched via Carbon RegisterEventHotKey
            // and never routed through AppKit's local key handler. If a managed
            // cmux.json entry somehow stores one as a chord, arming the prefix
            // here would swallow the first stroke and leave the second one
            // orphaned, breaking that keystroke for the focused terminal/browser
            // input.
            guard action != .showHideAllWindows && action != .globalSearch else { return false }
            guard !action.isBrowserContentShortcut else { return false }
            return KeyboardShortcutSettings.shortcut(for: action).hasChord
        }
    }

    func clearConfiguredShortcutChordState() {
        shortcutChordCoordinator.clear()
    }

    /// Coalesce shortcut-default changes and refresh on the next runloop turn to
    /// avoid mutating Bonsplit/SwiftUI-observed state during an active update pass.
    private func scheduleSplitButtonTooltipRefreshAcrossWorkspaces() {
        guard !splitButtonTooltipRefreshScheduled else { return }
        splitButtonTooltipRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitButtonTooltipRefreshScheduled = false
            self.refreshSplitButtonTooltipsAcrossWorkspaces()
        }
    }

    private func refreshSplitButtonTooltipsAcrossWorkspaces() {
        var refreshedManagers: Set<ObjectIdentifier> = []
        if let manager = tabManager {
            manager.refreshSplitButtonTooltips()
            refreshedManagers.insert(ObjectIdentifier(manager))
        }
        for context in registeredMainWindows {
            let manager = context.tabManager
            let identifier = ObjectIdentifier(manager)
            guard refreshedManagers.insert(identifier).inserted else { continue }
            manager.refreshSplitButtonTooltips()
        }
    }

    private func installGhosttyConfigObserver() {
        guard ghosttyConfigObserver == nil else { return }
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshGhosttyGotoSplitShortcuts() }
        }
    }

    @objc func reloadConfigurationMenuItem(_ sender: Any?) {
        reloadConfiguration(source: "menu.reload_configuration")
    }

    func installReloadConfigurationMenuItemAction() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        appMenu.delegate = self
        configureReloadConfigurationMenuItem(in: appMenu)
    }

    private func scheduleReloadConfigurationMenuItemRefresh() {
        guard !reloadConfigurationMenuItemRefreshScheduled else { return }
        reloadConfigurationMenuItemRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadConfigurationMenuItemRefreshScheduled = false
            self.installReloadConfigurationMenuItemAction()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === NSApp.mainMenu?.items.first?.submenu else { return }
        configureReloadConfigurationMenuItem(in: menu)
    }

    private func configureReloadConfigurationMenuItem(in menu: NSMenu) {
        guard let item = reloadConfigurationMenuItem(in: menu) else { return }

        item.identifier = Self.reloadConfigurationMenuItemIdentifier
        item.target = self
        item.action = #selector(reloadConfigurationMenuItem(_:))

        let shortcut = KeyboardShortcutSettings.menuShortcut(for: .reloadConfiguration)
        let resolved = appMenuCoordinator.reloadConfigurationKeyEquivalent(
            menuItemKeyEquivalent: shortcut.menuItemKeyEquivalent,
            modifierMask: shortcut.modifierFlags
        )
        item.keyEquivalent = resolved.keyEquivalent
        item.keyEquivalentModifierMask = resolved.modifierMask
    }

    private func reloadConfigurationMenuItem(in menu: NSMenu) -> NSMenuItem? {
        let reloadConfigurationTitle = String(
            localized: "menu.app.reloadConfiguration",
            defaultValue: "Reload Configuration"
        )
        guard let index = appMenuCoordinator.locateReloadConfigurationItem(
            in: menu.items.map { (identifier: $0.identifier?.rawValue, title: $0.title) },
            identifier: Self.reloadConfigurationMenuItemIdentifier.rawValue,
            localizedTitle: reloadConfigurationTitle
        ) else { return nil }
        return menu.items[index]
    }

    func reloadConfiguration(
        soft: Bool = false,
        source: String,
        reloadSettingsFromFile: Bool = true,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
#if DEBUG
        cmuxDebugLog("reload.config.request source=\(source) soft=\(soft)")
#endif
        GhosttyApp.shared.reloadConfiguration(
            soft: soft,
            source: source,
            reloadSettingsFromFile: reloadSettingsFromFile,
            preferredColorScheme: preferredColorScheme
        )
    }

    func reloadCmuxConfigStores(source: String) {
        configStoreReloadCoordinator.reload(source: source)
    }

    var reloadableConfigStores: [any CmuxConfigStoreReloading] {
        windowRegistry.contexts.compactMap { $0.configStore }
    }

    /// The per-window config store for `context`, resolved through the window's
    /// ``WindowContext`` in ``windowRegistry``.
    func configStore(for context: RegisteredMainWindow) -> CmuxConfigStore? {
        windowRegistry.context(for: WindowID(context.windowId))?.configStore
    }

    /// The per-window config store for the window owning `tabManager`, if any.
    func configStore(forTabManager tabManager: TabManager) -> CmuxConfigStore? {
        guard let context = registeredMainWindow(forManager: tabManager) else {
            return nil
        }
        return windowRegistry.context(for: WindowID(context.windowId))?.configStore
    }

    /// The first registered context whose window has a config store.
    func firstContextWithConfigStore() -> RegisteredMainWindow? {
        registeredMainWindows.first { windowRegistry.context(for: WindowID($0.windowId))?.configStore != nil }
    }

    func refreshWindowTitlesAfterConfigReload() {
        refreshWindowTitlesAcrossMainWindows()
    }

    private func refreshGhosttyGotoSplitShortcuts() {
        guard let config = GhosttyApp.shared.config else {
            ghosttyGotoSplitLeftShortcut = nil
            ghosttyGotoSplitRightShortcut = nil
            ghosttyGotoSplitUpShortcut = nil
            ghosttyGotoSplitDownShortcut = nil
            return
        }

        ghosttyGotoSplitLeftShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:left", UInt("goto_split:left".utf8.count))
        )
        ghosttyGotoSplitRightShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:right", UInt("goto_split:right".utf8.count))
        )
        ghosttyGotoSplitUpShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:up", UInt("goto_split:up".utf8.count))
        )
        ghosttyGotoSplitDownShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:down", UInt("goto_split:down".utf8.count))
        )
    }

    private func storedShortcutFromGhosttyTrigger(_ trigger: ghostty_input_trigger_s) -> StoredShortcut? {
        guard let shortcut = GhosttyTriggerShortcut(ghosttyConfigTrigger: trigger) else { return nil }
        return StoredShortcut(
            key: shortcut.key,
            command: shortcut.command,
            shift: shortcut.shift,
            option: shortcut.option,
            control: shortcut.control
        )
    }

    private func handleQuitShortcutWarning() -> Bool {
        guard activeQuitConfirmationAlertPresenter == nil else { return true }
        if !QuitConfirmationStore(defaults: .standard).shouldShowConfirmation(
            isQuitWarningConfirmed: false,
            hasDirtyWorkspaces: hasQuitConfirmationDirtyWorkspaces(),
            isDevBuild: BuildFlavor.current == .dev
        ) {
            NSApp.terminate(nil)
            return true
        }

        presentQuitConfirmation(ownsTerminateRequest: false) { [weak self] response, suppressionState in
            if suppressionState == .on {
                QuitConfirmationStore(defaults: .standard).setEnabled(false)
            }

            if response == .alertFirstButtonReturn {
                // Mark as confirmed so applicationShouldTerminate does not show a
                // second alert when NSApp.terminate re-enters the delegate callback.
                self?.terminateReply.markQuitWarningConfirmed()
                NSApp.terminate(nil)
            }
        }
        return true
    }

    func promptRenameSelectedWorkspace() -> Bool {
        guard let tabManager,
              let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            NSSound.beep()
            return false
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "dialog.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "dialog.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return true }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
        return true
    }

    private func handleCustomShortcut(event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            clearConfiguredShortcutChordState()
            return false
        }
        // A recorder being armed must suppress every app-level shortcut so the
        // keystroke reaches it to be rebound. The legacy in-app recorder signals
        // this via `KeyboardShortcutRecorderActivity`; the live Settings UI uses
        // the `CmuxSettingsUI` package recorder, which publishes its own armed
        // flag (it cannot reach the app-target activity type). Honor both — or
        // the numbered ⌃/⌘1–9 handler below silently eats keystrokes mid-record
        // and the recorder never captures (issue #5189).
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive,
              !RecorderHostButton.isActivelyRecording else {
            clearConfiguredShortcutChordState()
            return false
        }

        // `charactersIgnoringModifiers` can be nil for some synthetic NSEvents and certain special keys.
        // Treat nil as "" and rely on keyCode/layout-aware fallback logic where needed.
        // When a non-Latin input source is active (Korean, Chinese, Japanese, etc.),
        // charactersIgnoringModifiers returns non-ASCII characters that never match
        // Latin shortcut keys. Normalize via KeyboardLayout so downstream comparisons
        // (Cmd+1-9, Ctrl+1-9, omnibar N/P, command palette, etc.) work correctly.
        let chars = KeyboardLayout.normalizedCharacters(for: event)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasControl = flags.contains(.control)
        let hasCommand = flags.contains(.command)
        let hasOption = flags.contains(.option)
        let isControlOnly = hasControl && !hasCommand && !hasOption
        let controlDChar = chars == "d" || event.characters == "\u{04}"
        let isControlD = isControlOnly && (controlDChar || event.keyCode == 2)
        let configuredShortcutEventWindowNumber = configuredShortcutChordWindowNumber(for: event)
        shortcutChordCoordinator.prepareForEvent(windowNumber: configuredShortcutEventWindowNumber)
        defer { activeConfiguredShortcutChordPrefixForCurrentEvent = nil; clearShortcutEventFocusContextCache(for: event) }
#if DEBUG
        if isControlD {
            writeChildExitKeyboardProbe(
                [
                    "probeAppShortcutCharsHex": childExitKeyboardProbeHex(event.characters),
                    "probeAppShortcutCharsIgnoringHex": childExitKeyboardProbeHex(event.charactersIgnoringModifiers),
                    "probeAppShortcutKeyCode": String(event.keyCode),
                    "probeAppShortcutModsRaw": String(event.modifierFlags.rawValue),
                ],
                increments: ["probeAppShortcutCtrlDSeenCount": 1]
            )
        }
#endif

        // Don't steal shortcuts from close-confirmation alerts. Keep standard alert key
        // equivalents working and avoid surprising actions while the confirmation is up.
        let closeConfirmationTitles = [
            String(localized: "dialog.closeWorkspace.title", defaultValue: "Close workspace?"),
            String(localized: "dialog.closeWorkspaces.title", defaultValue: "Close workspaces?"),
            String(localized: "dialog.closeTab.title", defaultValue: "Close tab?"),
            String(localized: "dialog.closeOtherTabs.title", defaultValue: "Close other tabs?"),
            String(localized: "dialog.closeWindow.title", defaultValue: "Close window?"),
        ]
        let closeConfirmationPanel = NSApp.windows
            .compactMap { $0 as? NSPanel }
            .first { panel in
                guard panel.isVisible, let root = panel.contentView else { return false }
                return closeConfirmationTitles.contains { title in
                    findStaticText(in: root, equals: title)
                }
            }
        if let closeConfirmationPanel {
            // Special-case: Cmd+D should confirm destructive close on alerts.
            // XCUITest key events often hit the app-level local monitor first, so forward the key
            // equivalent to the alert panel explicitly.
            if matchShortcut(
                event: event,
                shortcut: StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            ),
               let root = closeConfirmationPanel.contentView,
               let closeButton = findButton(
                   in: root,
                   titled: String(localized: "common.close", defaultValue: "Close")
               ) {
                closeButton.performClick(nil)
                return true
            }
            return false
        }

        if NSApp.modalWindow != nil || shortcutRoutingKeyWindow?.attachedSheet != nil {
            return false
        }

        if browserFocusModePanelForShortcutEvent(event) != nil {
#if DEBUG
            cmuxDebugLog("browser.focusMode.shortcutMonitor.bypass \(debugShortcutRouteSnapshot(event: event))")
#endif
            return false
        }

        let normalizedFlags = flags.subtracting([.numericPad, .function, .capsLock])
        let commandPaletteTargetWindow = commandPaletteWindowForShortcutEvent(event)
        let isPlainEscape = normalizedFlags.isEmpty && event.keyCode == 53
        if !isPlainEscape {
            let textBoxShortcutTabManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            textBoxShortcutTabManager?.clearFocusedTerminalTextBoxHideEscapeArm()
        }
        let commandPaletteShortcutWindow = CommandPaletteShortcutEventOwnership(
            paletteWindow: commandPaletteTargetWindow
        ).ownsShortcutEvent(event) ? commandPaletteTargetWindow : nil
        let commandPaletteVisibleInTargetWindow = commandPaletteShortcutWindow.map {
            isCommandPaletteVisible(for: $0)
        } ?? false
        let commandPalettePendingOpenInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPalettePendingOpen(for: $0)
        } ?? false
        let commandPaletteOverlayVisibleInTargetWindow = commandPaletteTargetWindow.map {
            $0.isCommandPaletteOverlayPresented
        } ?? false
        let commandPaletteResponderActiveInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPaletteResponderActive(in: $0)
        } ?? false
        let commandPaletteInteractiveInTargetWindow =
            commandPaletteVisibleInTargetWindow
            || commandPaletteOverlayVisibleInTargetWindow
            || commandPaletteResponderActiveInTargetWindow
        let commandPaletteEffectiveInTargetWindow =
            commandPaletteInteractiveInTargetWindow
            || commandPalettePendingOpenInTargetWindow

#if DEBUG
        if event.keyCode == 36 || event.keyCode == 76 {
            cmuxDebugLog(
                "shortcut.return.raw " +
                "interactive=\(commandPaletteInteractiveInTargetWindow ? 1 : 0) " +
                "effective=\(commandPaletteEffectiveInTargetWindow ? 1 : 0) " +
                "target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "shortcutWindow={\(debugWindowToken(commandPaletteShortcutWindow))} " +
                "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0) " +
                "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                "pendingTarget=\(commandPalettePendingOpenInTargetWindow ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
        }
#endif

        if isPlainEscape {
            let activePaletteWindow = activeCommandPaletteWindow()
            let escapePaletteWindow: NSWindow? = {
                if let targetWindow = commandPaletteTargetWindow {
                    guard commandPaletteEffectiveInTargetWindow else {
                        return nil
                    }
                    return targetWindow
                }
                return activePaletteWindow
            }()
#if DEBUG
            cmuxDebugLog(
                "shortcut.escape route target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "active={\(debugWindowToken(activePaletteWindow))} " +
                "visibleTarget=\(commandPaletteVisibleInTargetWindow ? 1 : 0) " +
                "pendingTarget=\(commandPalettePendingOpenInTargetWindow ? 1 : 0) " +
                "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0) " +
                "effectiveTarget=\(commandPaletteEffectiveInTargetWindow ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
            if commandPaletteTargetWindow != nil,
               !commandPaletteVisibleInTargetWindow,
               !commandPalettePendingOpenInTargetWindow,
               (commandPaletteOverlayVisibleInTargetWindow || commandPaletteResponderActiveInTargetWindow) {
                cmuxDebugLog(
                    "shortcut.escape stateMismatch target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                    "overlayTarget=\(commandPaletteOverlayVisibleInTargetWindow ? 1 : 0) " +
                    "responderTarget=\(commandPaletteResponderActiveInTargetWindow ? 1 : 0)"
                )
            }
#endif
            if let paletteWindow = escapePaletteWindow,
               isCommandPaletteEffectivelyVisible(in: paletteWindow) {
                if commandPaletteMarkedTextInput(in: paletteWindow) != nil {
#if DEBUG
                    cmuxDebugLog(
                        "shortcut.escape imeMarkedTextBypass consumed=0 target={\(debugWindowToken(paletteWindow))}"
                    )
#endif
                    return false
                }
                clearCommandPalettePendingOpen(for: paletteWindow)
                beginCommandPaletteEscapeSuppression(for: paletteWindow)
                NotificationCenter.default.post(name: .commandPaletteDismissRequested, object: paletteWindow)
#if DEBUG
                cmuxDebugLog("shortcut.escape paletteDismiss consumed=1 target={\(debugWindowToken(paletteWindow))}")
#endif
                return true
            }
            let suppressionWindow = commandPaletteTargetWindow
                ?? event.window
                ?? shortcutRoutingActiveWindow
            if shouldConsumeSuppressedEscape(event: event, window: suppressionWindow) {
#if DEBUG
                cmuxDebugLog(
                    "shortcut.escape suppressionConsume consumed=1 target={\(debugWindowToken(suppressionWindow))} " +
                    "repeat=\(event.isARepeat ? 1 : 0)"
                )
#endif
                return true
            }
            if let requestAge = recentCommandPaletteRequestAge(for: suppressionWindow) {
                beginCommandPaletteEscapeSuppression(for: suppressionWindow)
#if DEBUG
                cmuxDebugLog(
                    "shortcut.escape requestGraceConsume consumed=1 target={\(debugWindowToken(suppressionWindow))} " +
                    "ageMs=\(Int(requestAge * 1000)) repeat=\(event.isARepeat ? 1 : 0)"
                )
#endif
                return true
            }
#if DEBUG
            cmuxDebugLog(
                "shortcut.escape paletteDismiss consumed=0 target={\(debugWindowToken(commandPaletteTargetWindow))} " +
                "active={\(debugWindowToken(activePaletteWindow))}"
            )
#endif
        }

        let paletteUsesInlineTextHandling = commandPaletteShortcutWindow.map { isCommandPaletteMultilineTextResponderActive(in: $0) } ?? false

        let paletteSelectionDelta = commandPaletteSelectionDeltaForKeyboardNavigation(flags: event.modifierFlags, chars: chars, keyCode: event.keyCode, nextShortcut: KeyboardShortcutSettings.shortcutIfBound(for: .commandPaletteNext), previousShortcut: KeyboardShortcutSettings.shortcutIfBound(for: .commandPalettePrevious))

        if CommandPaletteSelectionNavigation(
            delta: paletteSelectionDelta,
            isInteractive: commandPaletteInteractiveInTargetWindow,
            usesInlineTextHandling: paletteUsesInlineTextHandling
        ).shouldRoute,
           let delta = paletteSelectionDelta,
           let paletteWindow = commandPaletteShortcutWindow {
            NotificationCenter.default.post(name: .commandPaletteMoveSelection, object: paletteWindow, userInfo: ["delta": delta])
            return true
        }

        let shouldRouteConfiguredPaletteSelection = commandPaletteShortcutWindow != nil && CommandPaletteSelectionNavigation(delta: 1, isInteractive: commandPaletteInteractiveInTargetWindow, usesInlineTextHandling: paletteUsesInlineTextHandling).shouldRoute

        if shouldRouteConfiguredPaletteSelection, let paletteWindow = commandPaletteShortcutWindow {
            for (action, delta) in [(KeyboardShortcutSettings.Action.commandPaletteNext, 1), (.commandPalettePrevious, -1)] {
                guard KeyboardShortcutSettings.shortcut(for: action).hasChord, matchConfiguredShortcut(event: event, action: action) else { continue }
                NotificationCenter.default.post(name: .commandPaletteMoveSelection, object: paletteWindow, userInfo: ["delta": delta])
                return true
            }
        }

        if commandPaletteInteractiveInTargetWindow,
           let paletteWindow = commandPaletteShortcutWindow {
            let paletteFieldEditorHasMarkedText = CommandPaletteShortcutEventOwnership(
                paletteWindow: paletteWindow
            ).fieldEditorHasMarkedText
            let paletteSnapshot = mainWindowId(for: paletteWindow).map(commandPaletteSnapshot(windowId:)) ?? .empty
            let paletteUsesInlineReturnHandling = paletteUsesInlineTextHandling
            if isPlainEscape {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteDismissRequested, object: paletteWindow)
                return true
            }

            let shouldSubmitPalette = CommandPaletteKeystroke(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                characters: chars
            ).shouldSubmitWithReturn(mode: paletteSnapshot.mode)
#if DEBUG
            if event.keyCode == 36 || event.keyCode == 76 {
                cmuxDebugLog(
                    "shortcut.palette.return target={\(debugWindowToken(paletteWindow))} " +
                    "mode=\(paletteSnapshot.mode) " +
                    "inline=\(paletteUsesInlineReturnHandling ? 1 : 0) " +
                    "submit=\(shouldSubmitPalette ? 1 : 0) " +
                    "marked=\(paletteFieldEditorHasMarkedText ? 1 : 0) " +
                    "\(debugShortcutRouteSnapshot(event: event))"
                )
            }
#endif
            if paletteUsesInlineReturnHandling,
               event.keyCode == 36 || event.keyCode == 76 {
                return false
            }
            if shouldSubmitPalette {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteSubmitRequested, object: paletteWindow)
                return true
            }
        }

        // Guard against a stale tracked address-bar panel after focus transitions
        // (e.g., split that doesn't properly blur the address bar). If the first responder
        // is a terminal surface, the address bar can't be focused.
        if browserOmnibarFocusTracker.focusedPanelId != nil,
           cmuxOwningGhosttyView(for: shortcutRoutingKeyWindow?.firstResponder) != nil {
#if DEBUG
            let stalePanelToken = browserOmnibarFocusTracker.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            let firstResponderType = shortcutRoutingKeyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            cmuxDebugLog(
                "browser.focus.addressBar.staleClear panel=\(stalePanelToken) " +
                "reason=terminal_first_responder fr=\(firstResponderType)"
            )
#endif
            browserOmnibarFocusTracker.clearFocus()
        }

        let focusedAddressBarPanelIdInShortcutContext = focusedBrowserAddressBarPanelIdForShortcutEvent(event)
        let hasFocusedAddressBarInShortcutContext = focusedAddressBarPanelIdInShortcutContext != nil

        if shouldRouteConfiguredPaletteSelection, activeConfiguredShortcutChordPrefixForCurrentEvent == nil, armConfiguredShortcutChordIfNeeded(event: event, actions: [.commandPaletteNext, .commandPalettePrevious]) {
            return true
        }

        if commandPaletteEffectiveInTargetWindow {
            if matchConfiguredShortcut(event: event, action: .commandPalette) {
                let targetWindow = commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
                requestCommandPaletteCommands(preferredWindow: targetWindow, source: "shortcut.commandPalette")
                return true
            }

            if !hasFocusedAddressBarInShortcutContext,
               matchConfiguredShortcut(event: event, action: .goToWorkspace) {
                let targetWindow = commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
                requestCommandPaletteSwitcher(preferredWindow: targetWindow, source: "shortcut.goToWorkspace")
                return true
            }

            if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
               armConfiguredShortcutChordIfNeeded(event: event, actions: [.commandPalette]) {
                return true
            }

            if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
               !hasFocusedAddressBarInShortcutContext,
               armConfiguredShortcutChordIfNeeded(event: event, actions: [.goToWorkspace]) {
                return true
            }
        }

        if CommandPaletteKeystroke(
            keyCode: event.keyCode,
            modifierFlags: normalizedFlags,
            characters: chars
        ).shouldConsumeWhilePaletteVisible(isPaletteVisible: commandPaletteEffectiveInTargetWindow) {
            return true
        }

        if isPlainEscape {
            let escapeWindow = resolvedShortcutEventWindow(event) ?? shortcutRoutingActiveWindow
            let textBoxShortcutTabManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            if let escapeWindow,
               isMainTerminalWindow(escapeWindow) {
                if textBoxShortcutTabManager?.consumeFocusedTerminalTextBoxHideEscapeIfArmed(in: escapeWindow) == true {
                    return true
                }
            } else {
                textBoxShortcutTabManager?.clearFocusedTerminalTextBoxHideEscapeArm()
            }
            if escapeWindow?.firstResponder is TextBoxInputTextView {
                return false
            }
        }

        // When the terminal has active IME composition (e.g. Korean, Japanese, Chinese
        // input), don't intercept non-Cmd key events — let them flow through to the
        // input method. Cmd-based shortcuts (Cmd+T, Cmd+Shift+L, etc.) should still
        // work during composition since Cmd is never part of IME input sequences.
        if !normalizedFlags.contains(.command),
           let ghosttyView = cmuxOwningGhosttyView(for: shortcutRoutingKeyWindow?.firstResponder),
           ghosttyView.hasMarkedText() {
            return false
        }

        let shortcutWindowForMarkedText = resolvedShortcutEventWindow(event) ?? event.window ?? shortcutRoutingActiveWindow
        if browserOmnibarShouldBypassShortcutRoutingForMarkedText(
            hasFocusedAddressBar: hasFocusedAddressBarInShortcutContext,
            firstResponderHasMarkedText: browserResponderHasMarkedText(shortcutWindowForMarkedText?.firstResponder),
            flags: event.modifierFlags
        ) {
            return false
        }

        // When the notifications popover is open, Escape should dismiss it immediately.
        if flags.isEmpty, event.keyCode == 53, titlebarAccessoryController.dismissNotificationsPopoverIfShown() {
            return true
        }

        // When the notifications popover is showing an empty state, consume plain typing
        // so key presses do not leak through into the focused terminal.
        if flags.isDisjoint(with: [.command, .control, .option]),
           titlebarAccessoryController.isNotificationsPopoverShown(),
           (notificationStore?.notifications.isEmpty ?? false) {
            return true
        }

        if shouldBypassPrintableOptionTextForShortcutRouting(event: event) {
            return false
        }

        let canvasSurfaceDigitShortcutIsActive =
            shortcutEventFocusContext(event).shortcutContext.bool(ShortcutContextKnownKey.workspaceCanvasLayout.rawValue) &&
            shortcutWhenClauseAllows(action: .selectSurfaceByNumber, event: event) &&
            numberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) != nil

        if !canvasSurfaceDigitShortcutIsActive,
           let mode = rightSidebarModeShortcut(for: event),
           let rightSidebarWindow = mainWindowForShortcutEvent(event) ?? event.window ?? shortcutRoutingActiveWindow,
           shouldRouteRightSidebarModeShortcut(in: rightSidebarWindow) {
            _ = focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: rightSidebarWindow
            )
            return true
        }

        let hasEventWindowContext = shortcutEventHasAddressableWindow(event)
        let didSynchronizeShortcutContext = synchronizeShortcutRoutingContext(event: event)
        if hasEventWindowContext && !didSynchronizeShortcutContext {
            if handleDetachedInspectorCloseShortcutOutsideMainContext(event: event) {
                return true
            }
#if DEBUG
            cmuxDebugLog("handleCustomShortcut: unresolved event window context; bypassing app shortcut handling")
#endif
            return false
        }
        if cmuxCloseFocusedTerminalFindForEscape(event: event, appDelegate: self) { return true }
        if matchConfiguredShortcut(event: event, action: .find) {
            let shortcutWindow = resolvedShortcutEventWindow(event)
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: tabManager, window: shortcutWindow ?? shortcutRoutingKeyWindow); return performFindShortcutInActiveMainWindow(preferredWindow: shortcutWindow)
        }

        // Keep keyboard routing deterministic after split close/reparent transitions:
        // before processing shortcuts, converge first responder with the focused terminal panel.
        if isControlD {
#if DEBUG
            let selected = tabManager?.selectedTabId?.uuidString.prefix(5) ?? "nil"
            let focused = tabManager?.selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil"
            let frType = shortcutRoutingKeyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            cmuxDebugLog("shortcut.ctrlD stage=preReconcile selected=\(selected) focused=\(focused) fr=\(frType)")
#endif
            tabManager?.reconcileFocusedPanelFromFirstResponderForKeyboard()
            #if DEBUG
            let frAfterType = shortcutRoutingKeyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            cmuxDebugLog("shortcut.ctrlD stage=postReconcile fr=\(frAfterType)")
            writeChildExitKeyboardProbe([:], increments: ["probeAppShortcutCtrlDPassedCount": 1])
            #endif
            // Ctrl+D belongs to the focused terminal surface; never treat it as an app shortcut.
            return false
        }
        // Chrome-like omnibar navigation while holding Ctrl+N / Ctrl+P.
        if let delta = controlOmnibarSelectionDelta(
            hasFocusedAddressBar: hasFocusedAddressBarInShortcutContext,
            flags: flags,
            chars: chars
        ),
           let focusedAddressBarPanelIdInShortcutContext {
            dispatchBrowserOmnibarSelectionMove(panelId: focusedAddressBarPanelIdInShortcutContext, delta: delta)
            startBrowserOmnibarSelectionRepeatIfNeeded(
                panelId: focusedAddressBarPanelIdInShortcutContext,
                keyCode: event.keyCode,
                delta: delta
            )
            return true
        }

        if let delta = browserOmnibarSelectionDeltaForArrowNavigation(
            hasFocusedAddressBar: hasFocusedAddressBarInShortcutContext,
            flags: event.modifierFlags,
            keyCode: event.keyCode
        ),
           let focusedAddressBarPanelIdInShortcutContext {
            dispatchBrowserOmnibarSelectionMove(panelId: focusedAddressBarPanelIdInShortcutContext, delta: delta)
            return true
        }

        // Fast path for normal typing and terminal navigation keys (for example Up-arrow
        // history): after command-palette/notification handling and browser omnibar
        // arrow navigation above, most plain key events have no app-level shortcut behavior.
        if shouldBypassPlainKeyShortcutRouting(event: event, normalizedFlags: normalizedFlags) {
            return false
        }

        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil {
            let shortcutContext = shortcutEventFocusContext(event).shortcutContext
            let availableChordActions = currentConfiguredShortcutChordActions().filter { action in
                // Arm by the effective `when` clause (its shortcuts.when override or
                // the built-in context default), matching the keyDown gate, so a
                // `when`-broadened chord arms in its allowed context and a narrowed
                // one does not swallow its first stroke elsewhere (issue #5189).
                KeyboardShortcutSettings.effectiveWhenClause(for: action).evaluate(shortcutContext)
            }
            if armConfiguredShortcutChordIfNeeded(event: event, actions: availableChordActions) {
                return true
            }
        }

        let configuredCmuxShortcutContext = preferredMainWindowContextForShortcutRouting(event: event)
        let configuredCmuxShortcutActions = configuredCmuxShortcutActions(for: configuredCmuxShortcutContext)

        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           armConfiguredShortcutChordIfNeeded(
               event: event,
               actions: [],
               shortcuts: configuredCmuxShortcutActions.compactMap { $0.shortcut }
           ) {
            return true
        }

        // Focused browser web content owns document-editing command equivalents
        // (copy/cut/select-all/italic). Yield them so e.g. Cmd+I italicizes in web
        // writing apps (Notion, Google Docs, …) instead of opening Show
        // Notifications. This special-cases only the editing collision: the action
        // stays generally available, so non-colliding custom bindings (e.g.
        // Cmd+Shift+I) still open notifications from a browser pane. Gated to the
        // actual web view owning first responder — not just the browser being the
        // selected pane — so Cmd+I keeps working when the sidebar, address bar, or
        // other chrome holds focus, and to the no-active-chord case so a configured
        // chord whose second stroke is Cmd+I/C/X/A still completes (issue #6776).
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(event),
           shortcutEventFirstResponderOwnsBrowserWebView(event) {
            return false
        }

        if !hasFocusedAddressBarInShortcutContext,
           shouldRouteInlineVSCodeCommandPaletteShortcutThroughWebContentFirst(
               event,
               pageURL: shortcutEventBrowserPanel(event)?.webView.url
           ) {
            return false
        }

        if matchConfiguredShortcut(event: event, action: .commandPalette) {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
            requestCommandPaletteCommands(preferredWindow: targetWindow, source: "shortcut.commandPalette")
            return true
        }

        if !hasFocusedAddressBarInShortcutContext,
           matchConfiguredShortcut(event: event, action: .goToWorkspace) {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
            requestCommandPaletteSwitcher(preferredWindow: targetWindow, source: "shortcut.goToWorkspace")
            return true
        }

        if matchConfiguredShortcut(event: event, action: .quit) {
            return handleQuitShortcutWarning()
        }
        if matchConfiguredShortcut(event: event, action: .openSettings) {
            openPreferencesWindow(debugSource: "shortcut.openSettings")
            return true
        }
        if matchConfiguredShortcut(event: event, action: .reloadConfiguration) {
            reloadConfiguration(source: "shortcut.reloadConfiguration")
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleFullScreen) {
            guard let targetWindow = mainWindowForShortcutEvent(event) else {
                return false
            }
            targetWindow.toggleFullScreen(nil)
            return true
        }

        if handleConfiguredCmuxShortcut(
            event: event,
            actions: configuredCmuxShortcutActions,
            context: configuredCmuxShortcutContext
        ) {
            return true
        }

        // Primary UI shortcuts
        if matchConfiguredShortcut(event: event, action: .toggleSidebar) {
            _ = toggleSidebarInActiveMainWindow(preferredWindow: mainWindowForShortcutEvent(event))
            return true
        }

        if matchConfiguredShortcut(event: event, action: .newTab) {
#if DEBUG
            cmuxDebugLog("shortcut.action name=newWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
            performNewWorkspaceAction(event: event, debugSource: "shortcut.cmdN")
            return true
        }

        if matchConfiguredShortcut(event: event, action: .newBrowserWorkspace) {
#if DEBUG
            cmuxDebugLog("shortcut.action name=newBrowserWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
            performNewBrowserWorkspaceAction(event: event, debugSource: "shortcut.optCmdN")
            return true
        }

        // New Window: Cmd+Shift+N
        // Handled here instead of relying on SwiftUI's CommandGroup menu item because
        // after a browser panel has been shown, SwiftUI's menu dispatch can silently
        // consume the key equivalent without firing the action closure.
        if matchConfiguredShortcut(event: event, action: .newWindow) {
            openNewMainWindow(preferredWindow: mainWindowForShortcutEvent(event))
            return true
        }

        // Open Folder: Cmd+O
        // Handled here to prevent AppKit's default NSDocumentController from opening
        // the Documents folder when SwiftUI menu dispatch fails due to focus bugs.
        if matchConfiguredShortcut(event: event, action: .openFolder) {
            showOpenFolderPanel()
            return true
        }

        // Check Show Notifications shortcut
        if matchConfiguredShortcut(event: event, action: .showNotifications) {
            toggleNotificationsPopover(animated: false, anchorView: fullscreenControlsViewModel?.notificationsAnchorView)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .openDiffViewer) {
            // Shares the command palette's diff-open path; targets the event window's
            // focused workspace and beeps if it can't be opened (matching the palette).
            let manager = activeTabManagerForCommands(preferredWindow: mainWindowForShortcutEvent(event))
            if !openDiffViewerForFocusedWorkspace(for: manager) {
                NSSound.beep()
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleRightSidebar) {
            // Escape AppKit's performKeyEquivalent animation context. Without
            // deferring the toggle, NSAnimationContext implicitly animates the
            // layout change.
            let preferredWindow = mainWindowForShortcutEvent(event) ?? event.window ?? shortcutRoutingActiveWindow
            DispatchQueue.main.async { [weak self, weak preferredWindow] in
                _ = self?.toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow)
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusRightSidebar) {
            let preferredWindow = mainWindowForShortcutEvent(event)
#if DEBUG
            let beforeResponder = shortcutRoutingFirstResponder(preferredWindow: preferredWindow)
            dlog(
                "rs.focus.toggle.shortcut.begin event=\(event.cmuxKeyDescription) " +
                "preferred={\(debugWindowToken(preferredWindow))} fr=\(beforeResponder.map { String(describing: type(of: $0)) } ?? "nil") " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            let result = toggleRightSidebarKeyboardFocusInActiveMainWindow(preferredWindow: preferredWindow)
#if DEBUG
            let afterResponder = shortcutRoutingFirstResponder(preferredWindow: preferredWindow)
            dlog(
                "rs.focus.toggle.shortcut.end result=\(result ? 1 : 0) " +
                "preferred={\(debugWindowToken(preferredWindow))} fr=\(afterResponder.map { String(describing: type(of: $0)) } ?? "nil") " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            return true
        }

        if matchConfiguredShortcut(event: event, action: .sendFeedback) {
            guard let targetContext = preferredMainWindowContextForShortcuts(event: event),
                  let targetWindow = targetContext.window ?? windowForMainWindowId(targetContext.windowId) else {
                return false
            }
            setActiveMainWindow(targetWindow)
            bringToFront(targetWindow)
            NotificationCenter.default.post(name: .feedbackComposerRequested, object: targetWindow)
            return true
        }

        // Check Jump to Unread shortcut
        if matchConfiguredShortcut(event: event, action: .jumpToUnread) {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadShortcutHandled": "1"])
            }
#endif
            jumpToLatestUnread()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleUnread) {
            toggleFocusedNotificationUnread(
                preferredWindow: mainWindowForShortcutEvent(event)
            )
            return true
        }

        if matchConfiguredShortcut(event: event, action: .markOldestUnreadAndJumpNext) {
            markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
                preferredWindow: mainWindowForShortcutEvent(event)
            )
            return true
        }

        // Flash the currently focused panel so the user can visually confirm focus.
        if matchConfiguredShortcut(event: event, action: .triggerFlash) {
            let targetManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            targetManager?.triggerFocusFlash()
            return true
        }

        // Surface navigation: Cmd+Shift+] / Cmd+Shift+[
        if matchConfiguredShortcut(event: event, action: .nextSurface) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .prevSurface) {
            tabManager?.selectPreviousSurface()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleTerminalCopyMode) {
            let handled = tabManager?.toggleFocusedTerminalCopyMode() ?? false
#if DEBUG
            cmuxDebugLog(
                "shortcut.action name=toggleTerminalCopyMode handled=\(handled ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            // Only consume when a focused terminal actually handled the toggle.
            // Otherwise allow the event to continue through the responder chain.
            return handled
        }

        if matchConfiguredShortcut(event: event, action: .focusTextBoxInput) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            let handled = routedManager?.focusFocusedTerminalTextBoxInputOrTerminal() ?? false
            return handled
        }

        if matchConfiguredShortcut(event: event, action: .attachTextBoxFile) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            let handled = routedManager?.attachFileToFocusedTerminalTextBoxInput() ?? false
            return handled
        }

        if matchConfiguredShortcut(event: event, action: .sendCtrlFToTerminal) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            let handled = routedManager?.sendCtrlFToFocusedTerminal() ?? false
#if DEBUG
            cmuxDebugLog(
                "shortcut.action name=sendCtrlFToTerminal handled=\(handled ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            // Only consume when a focused terminal actually received the chord.
            return handled
        }

        if matchConfiguredShortcut(event: event, action: .clearScreenKeepScrollback) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            let handled = routedManager?.clearFocusedTerminalKeepingScrollback() ?? false
#if DEBUG
            cmuxDebugLog(
                "shortcut.action name=clearScreenKeepScrollback handled=\(handled ? 1 : 0) " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            // Only consume when a focused terminal actually performed the clear.
            return handled
        }

        // Workspace navigation: Cmd+Ctrl+] / Cmd+Ctrl+[
        if matchConfiguredShortcut(event: event, action: .nextSidebarTab) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            cmuxDebugLog(
                "ws.shortcut dir=next repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectNextTab()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .prevSidebarTab) {
#if DEBUG
            let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            cmuxDebugLog(
                "ws.shortcut dir=prev repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            tabManager?.selectPreviousTab()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .renameWorkspace) {
            return requestRenameWorkspaceViaCommandPalette(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
            )
        }

        if matchConfiguredShortcut(event: event, action: .groupSelectedWorkspaces) {
            // Only consume the event when grouping actually happened; otherwise
            // fall through so the dispatcher reaches the later
            // `.toggleReactGrab` check (default ⌘⇧G collides with React Grab
            // and grouping returns false when no multi-selection exists).
            if handleGroupSelectedWorkspacesShortcut(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
            ) {
                return true
            }
        }

        if matchConfiguredShortcut(event: event, action: .newWorkspaceGroup) {
            return createEmptyWorkspaceGroup(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
            )
        }

        if matchConfiguredShortcut(event: event, action: .toggleFocusedWorkspaceGroupCollapsed) {
            // Only consume the event when the toggle actually fired (focused
            // workspace was in a group). Otherwise fall through so a rebinding
            // that shares this chord with another action still works.
            if handleToggleFocusedWorkspaceGroupCollapsedShortcut(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
            ) {
                return true
            }
        }

        if matchConfiguredShortcut(event: event, action: .editWorkspaceDescription) {
#if DEBUG
            cmuxDebugLog(
                "shortcut.editWorkspaceDescription matched target={\(debugWindowToken(commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow))} " +
                "\(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            return requestEditWorkspaceDescriptionViaCommandPalette(
                preferredWindow: commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
            )
        }

        if matchConfiguredShortcut(event: event, action: .closeOtherTabsInPane) {
            if let targetWindow = event.window ?? shortcutRoutingActiveWindow,
               targetWindow.identifier?.rawValue == "cmux.settings" {
                targetWindow.performClose(nil)
            } else {
                let targetWindow = event.window ?? shortcutRoutingActiveWindow
                if let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow) {
                    terminalContext.tabManager.closeOtherTabsInFocusedPaneWithConfirmation()
                } else {
                    tabManager?.closeOtherTabsInFocusedPaneWithConfirmation()
                }
            }
            return true
        }

        // The Close Tab shortcut must close the focused panel even if first-responder
        // momentarily lags on a browser NSTextView during split focus transitions.
        if matchConfiguredShortcut(event: event, action: .closeTab) {
            let panels = allBrowserPanelsForInspectorWindowClose()
            if closeDetachedInspectorWindowForCloseShortcut(event: event, panels: panels) {
                return true
            }
            let routedManager = tabManagerForFocusedCloseShortcut(event: event)
            // Browser popup windows primarily intercept the configured Close Tab shortcut
            // in BrowserPopupPanel. This AppDelegate path is a fallback for cases where
            // AppKit routes the event through the global shortcut handler first.
            if let targetWindow = auxiliaryWindowForFocusedCloseShortcut(event: event) {
#if DEBUG
                let route = targetWindow.identifier?.rawValue == "cmux.browser-popup" ? "browserPopup" : "auxWindow"
                cmuxDebugLog("shortcut.closeTab route=\(route)")
#endif
                targetWindow.performClose(nil)
                return true
            } else {
                if let routedManager {
#if DEBUG
                    let selectedWorkspace = routedManager.selectedWorkspace
                    cmuxDebugLog(
                        "shortcut.closeTab route=workspaceModel workspace=\(selectedWorkspace?.id.uuidString.prefix(5) ?? "nil") " +
                        "panel=\(selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                        "selected=\(routedManager.selectedTabId?.uuidString.prefix(5) ?? "nil")"
                    )
#endif
                    routedManager.closeCurrentPanelWithConfirmation()
                } else {
#if DEBUG
                    cmuxDebugLog("shortcut.closeTab route=noManager")
#endif
                    return false
                }
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .closeWorkspace) {
            tabManagerForFocusedCloseShortcut(event: event)?.closeCurrentWorkspaceWithConfirmation()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .closeWindow) {
            guard let targetWindow = mainWindowForFocusedCloseShortcut(event: event) else {
                NSSound.beep()
                return true
            }
            _ = synchronizeActiveMainWindowContext(preferredWindow: targetWindow)
            closeWindowWithConfirmation(targetWindow)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .renameTab) {
            let targetWindow = commandPaletteTargetWindow ?? event.window ?? shortcutRoutingActiveWindow
            requestCommandPaletteRenameTab(preferredWindow: targetWindow, source: "shortcut.renameTab")
            return true
        }

        // Numeric shortcuts for specific workspaces (9 = last workspace)
        // Always consume the event when the digit matches to prevent Ghostty's
        // goto_tab fallback from creating a new window when the index is out of bounds.
        if let digit = routableNumberedConfiguredShortcutDigit(event: event, action: .selectWorkspaceByNumber) {
            if let manager = tabManagerForNumberedShortcut(event: event),
               let targetIndex = WorkspaceShortcutMapper(workspaceCount: manager.tabs.count).workspaceIndex(forDigit: digit) {
#if DEBUG
                cmuxDebugLog(
                    "shortcut.action name=workspaceDigit digit=\(digit) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
                )
#endif
                manager.selectTab(at: targetIndex)
            }
            return true
        }

        // Numeric shortcuts for surfaces within the focused pane (9 = last)
        if let digit = routableNumberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) {
            let manager = tabManagerForNumberedShortcut(event: event)
            if digit == 9 {
                manager?.selectLastSurface()
            } else {
                manager?.selectSurface(at: digit - 1)
            }
            return true
        }

        // Pane focus navigation (defaults to Cmd+Option+Arrow, but can be customized to letter/number keys).
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .focusLeft,
            arrowGlyph: "←",
            arrowKeyCode: 123
        ) || (ghosttyGotoSplitLeftShortcut.map { $0.matchesDirectionalShortcut(event: event, arrowGlyph: "←", arrowKeyCode: 123, layoutCharacterProvider: shortcutCoordinator.layoutCharacter(forKeyCode:modifierFlags:)) } ?? false) {
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: tabManager, window: shortcutRoutingKeyWindow); tabManager?.movePaneFocus(direction: .left)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .left)
#endif
            return true
        }
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .focusRight,
            arrowGlyph: "→",
            arrowKeyCode: 124
        ) || (ghosttyGotoSplitRightShortcut.map { $0.matchesDirectionalShortcut(event: event, arrowGlyph: "→", arrowKeyCode: 124, layoutCharacterProvider: shortcutCoordinator.layoutCharacter(forKeyCode:modifierFlags:)) } ?? false) {
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: tabManager, window: shortcutRoutingKeyWindow); tabManager?.movePaneFocus(direction: .right)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .right)
#endif
            return true
        }
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .focusUp,
            arrowGlyph: "↑",
            arrowKeyCode: 126
        ) || (ghosttyGotoSplitUpShortcut.map { $0.matchesDirectionalShortcut(event: event, arrowGlyph: "↑", arrowKeyCode: 126, layoutCharacterProvider: shortcutCoordinator.layoutCharacter(forKeyCode:modifierFlags:)) } ?? false) {
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: tabManager, window: shortcutRoutingKeyWindow); tabManager?.movePaneFocus(direction: .up)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .up)
#endif
            return true
        }
        if matchConfiguredDirectionalShortcut(
            event: event,
            action: .focusDown,
            arrowGlyph: "↓",
            arrowKeyCode: 125
        ) || (ghosttyGotoSplitDownShortcut.map { $0.matchesDirectionalShortcut(event: event, arrowGlyph: "↓", arrowKeyCode: 125, layoutCharacterProvider: shortcutCoordinator.layoutCharacter(forKeyCode:modifierFlags:)) } ?? false) {
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: tabManager, window: shortcutRoutingKeyWindow); tabManager?.movePaneFocus(direction: .down)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .down)
#endif
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleSplitZoom) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            _ = routedManager?.toggleFocusedSplitZoom()
#if DEBUG
            recordGotoSplitZoomIfNeeded(tabManager: routedManager)
#endif
            return true
        }
        if matchConfiguredShortcut(event: event, action: .equalizeSplits) { performEqualizeSplitsShortcut(); return true }
        // Canvas layout actions share one executor with the palette, View
        // menu, and the canvas.* socket verbs.
        for action in KeyboardShortcutSettings.Action.canvasActions {
            if matchConfiguredShortcut(event: event, action: action),
               let canvasAction = action.canvasAction {
                if let workspace = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager.selectedWorkspace
                    ?? tabManager?.selectedWorkspace {
                    CanvasActionExecutor(workspace: workspace).perform(canvasAction)
                }
                return true
            }
        }
        // Configured split actions.
        if matchConfiguredShortcut(event: event, action: .splitRight) {
#if DEBUG
            cmuxDebugLog("shortcut.action name=splitRight \(debugShortcutRouteSnapshot(event: event))")
#endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .right) {
                return true
            }
            _ = performSplitShortcut(
                direction: .right,
                preferredWindow: event.window ?? shortcutRoutingActiveWindow
            )
            return true
        }

        if matchConfiguredShortcut(event: event, action: .splitDown) {
#if DEBUG
            cmuxDebugLog("shortcut.action name=splitDown \(debugShortcutRouteSnapshot(event: event))")
#endif
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .down) {
                return true
            }
            _ = performSplitShortcut(
                direction: .down,
                preferredWindow: event.window ?? shortcutRoutingActiveWindow
            )
            return true
        }

        if matchConfiguredShortcut(event: event, action: .splitBrowserRight) {
#if DEBUG
            cmuxDebugLog("shortcut.action name=splitBrowserRight \(debugShortcutRouteSnapshot(event: event))")
#endif
            _ = performBrowserSplitShortcut(direction: .right)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .splitBrowserDown) {
#if DEBUG
            cmuxDebugLog("shortcut.action name=splitBrowserDown \(debugShortcutRouteSnapshot(event: event))")
#endif
            _ = performBrowserSplitShortcut(direction: .down)
            return true
        }

        // Surface navigation (legacy Ctrl+Tab support)
        if StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true).matchesTabShortcut(event: event) {
            tabManager?.selectNextSurface()
            return true
        }
        if StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true).matchesTabShortcut(event: event) {
            tabManager?.selectPreviousSurface()
            return true
        }

        // New surface: Cmd+T
        if matchConfiguredShortcut(event: event, action: .newSurface) {
            tabManager?.newSurface()
            return true
        }

        // Open browser: Cmd+Shift+L
        if matchConfiguredShortcut(event: event, action: .openBrowser) {
            _ = openBrowserAndFocusAddressBar(insertAtEnd: true)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusBrowserAddressBar) {
            if let focusedPanel = tabManager?.focusedBrowserPanel {
                focusBrowserAddressBar(in: focusedPanel)
                return true
            }

            if let trackedPanelId = browserOmnibarFocusTracker.focusedPanelId,
               focusBrowserAddressBar(panelId: trackedPanelId) {
                return true
            }

            if openBrowserAndFocusAddressBar(insertAtEnd: true) != nil {
                return true
            }
        }

        if matchConfiguredShortcut(event: event, action: .focusHistoryBack) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            if routedManager?.navigateBack() != true {
                NSSound.beep()
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusHistoryForward) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            if routedManager?.navigateForward() != true {
                NSSound.beep()
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleBrowserFocusMode) {
            // Reached only when focus mode is off (the active-focus-mode bypass
            // returns earlier), so this enters focus mode for the focused browser.
            // Exit stays double-Escape, which is forwarded to the page first.
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event),
                  focusedBrowserPanel.canToggleBrowserFocusMode else {
                return false
            }
            _ = focusedBrowserPanel.toggleBrowserFocusMode(reason: "configuredShortcut", focusWebView: true)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserBack) {
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event) else {
                return false
            }
            focusedBrowserPanel.goBack()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserForward) {
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event) else {
                return false
            }
            focusedBrowserPanel.goForward()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserReload) {
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event) else {
                return false
            }
            reloadBrowserPanelForShortcut(focusedBrowserPanel)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserHardReload) {
            guard let focusedBrowserPanel = shortcutEventBrowserPanel(event) else {
                return false
            }
            hardReloadBrowserPanelForShortcut(focusedBrowserPanel)
            return true
        }

        // Safari defaults:
        // - Option+Command+I => Show/Toggle Web Inspector
        // - Option+Command+C => Show JavaScript Console
        if matchConfiguredShortcut(event: event, action: .toggleBrowserDeveloperTools) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.pre", event: event)
#endif
            let didHandle = shortcutEventBrowserPanel(event)?.toggleDeveloperTools() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "toggle.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "toggle.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .showBrowserJavaScriptConsole) {
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.pre", event: event)
#endif
            let didHandle = shortcutEventBrowserPanel(event)?.showDeveloperToolsConsole() ?? false
#if DEBUG
            logDeveloperToolsShortcutSnapshot(phase: "console.post", event: event, didHandle: didHandle)
            DispatchQueue.main.async { [weak self] in
                self?.logDeveloperToolsShortcutSnapshot(phase: "console.tick", didHandle: didHandle)
            }
#endif
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleReactGrab) {
            let didHandle = tabManager?.toggleReactGrabFromCurrentFocus() ?? false
            if !didHandle { NSSound.beep() }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .browserZoomIn) { return performBrowserOrTextPreviewZoomShortcut(event: event, action: .browserZoomIn) }

        if matchConfiguredShortcut(event: event, action: .browserZoomOut) { return performBrowserOrTextPreviewZoomShortcut(event: event, action: .browserZoomOut) }

        if matchConfiguredShortcut(event: event, action: .browserZoomReset) { return performBrowserOrTextPreviewZoomShortcut(event: event, action: .browserZoomReset) }

        if matchConfiguredShortcut(event: event, action: .markdownZoomIn) {
            return shortcutEventMarkdownPanel(event)?.zoomIn() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .markdownZoomOut) {
            return shortcutEventMarkdownPanel(event)?.zoomOut() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .markdownZoomReset) {
            return shortcutEventMarkdownPanel(event)?.resetZoom() ?? false
        }

        if matchConfiguredShortcut(event: event, action: .findInDirectory) {
            return focusFileSearchInActiveMainWindow(preferredWindow: resolvedShortcutEventWindow(event))
        }

        if matchConfiguredShortcut(event: event, action: .findNext) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            restoreFocusedMainPanelFocusForShortcut(event: event)
            tabManager?.findNext()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .findPrevious) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            restoreFocusedMainPanelFocusForShortcut(event: event)
            tabManager?.findPrevious()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .hideFind) {
            guard !shouldLetFocusedBrowserOwnFindShortcut(event) else {
                return false
            }
            restoreFocusedMainPanelFocusForShortcut(event: event)
            tabManager?.hideFind()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .useSelectionForFind) {
            restoreFocusedMainPanelFocusForShortcut(event: event)
            tabManager?.searchSelection()
            return true
        }

        if matchConfiguredShortcut(event: event, action: .reopenPreviousSession) {
            if !reopenPreviousSession() {
                NSSound.beep()
            }
            return true
        }

        if matchConfiguredShortcut(event: event, action: .reopenClosedBrowserPanel) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            _ = reopenMostRecentlyClosedItem(preferredTabManager: routedManager)
            return true
        }

        return false
    }

    func shouldSuppressSplitShortcutForTransientTerminalFocusState(
        direction: SplitDirection? = nil,
        tabManager preferredTabManager: TabManager? = nil
    ) -> Bool {
        let targetTabManager = preferredTabManager ?? tabManager
        guard let targetTabManager,
              let workspace = targetTabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: focusedPanelId) else {
            return false
        }

        let hostedView = terminalPanel.hostedView
        let hostedSize = hostedView.bounds.size
        let hostedHiddenInHierarchy = hostedView.isHiddenOrHasHiddenAncestor
        let hostedAttachedToWindow = terminalPanel.surface.isViewInWindow
        let firstResponderIsWindow = shortcutRoutingKeyWindow?.firstResponder is NSWindow

        let shouldSuppress = shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
            firstResponderIsWindow: firstResponderIsWindow,
            hostedSize: hostedSize,
            hostedHiddenInHierarchy: hostedHiddenInHierarchy,
            hostedAttachedToWindow: hostedAttachedToWindow
        )
        guard shouldSuppress else { return false }

        targetTabManager.reconcileFocusedPanelFromFirstResponderForKeyboard()

#if DEBUG
        let directionLabel = direction.map { String(describing: $0) } ?? "splitGeometry"
        let firstResponderType = shortcutRoutingKeyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog(
            "split.shortcut suppressed dir=\(directionLabel) reason=transient_focus_state " +
            "fr=\(firstResponderType) hidden=\(hostedHiddenInHierarchy ? 1 : 0) " +
            "attached=\(hostedAttachedToWindow ? 1 : 0) " +
            "frame=\(String(format: "%.1fx%.1f", hostedSize.width, hostedSize.height))"
        )
#endif
        return true
    }

#if DEBUG
    private func logBrowserZoomShortcutTrace(
        stage: String,
        event: NSEvent,
        flags: NSEvent.ModifierFlags,
        chars: String,
        action: BrowserZoomShortcutAction? = nil,
        handled: Bool? = nil
    ) {
        guard browserZoomShortcutTraceCandidate(
            flags: flags,
            chars: chars,
            keyCode: event.keyCode,
            literalChars: event.characters
        ) else {
            return
        }

        let keyWindow = NSApp.keyWindow
        let firstResponderType = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let panel = tabManager?.focusedBrowserPanel
        let panelToken = panel.map { String($0.id.uuidString.prefix(8)) } ?? "nil"
        let panelZoom = panel?.webView.pageZoom ?? -1
        var line =
            "zoom.shortcut stage=\(stage) event=\(event.cmuxKeyDescription) " +
            "chars='\(chars)' flags=\(browserZoomShortcutTraceFlagsString(flags)) " +
            "action=\(browserZoomShortcutTraceActionString(action)) keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType) panel=\(panelToken) zoom=\(String(format: "%.3f", panelZoom)) " +
            "addrBarId=\(browserOmnibarFocusTracker.focusedPanelId?.uuidString.prefix(8) ?? "nil")"
        if let handled {
            line += " handled=\(handled ? 1 : 0)"
        }
        cmuxDebugLog(line)
    }

    private func browserFocusStateSnapshot() -> String {
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let focused = tabManager?.selectedWorkspace?.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let addressBar = browserOmnibarFocusTracker.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let keyWindow = NSApp.keyWindow?.windowNumber ?? -1
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "selected=\(selected) focused=\(focused) addr=\(addressBar) keyWin=\(keyWindow) fr=\(firstResponderType)"
    }

    private func redactedDebugURL(_ url: URL?) -> String {
        guard let url else { return "nil" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<redacted>"
    }
#endif

    @discardableResult
    func focusBrowserAddressBar(panelId: UUID) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panel = workspace.browserPanel(for: panelId) else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.route panel=\(panelId.uuidString.prefix(5)) " +
                "result=miss \(browserFocusStateSnapshot())"
            )
#endif
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) result=hit \(browserFocusStateSnapshot())"
        )
#endif
        workspace.focusPanel(panel.id)
#if DEBUG
        let focusedAfter = workspace.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "browser.focus.addressBar.route panel=\(panel.id.uuidString.prefix(5)) " +
            "workspace=\(workspace.id.uuidString.prefix(5)) focusedAfter=\(focusedAfter)"
        )
#endif
        focusBrowserAddressBar(in: panel)
        return true
    }

    @discardableResult
    func openBrowserAndFocusAddressBar(url: URL? = nil, insertAtEnd: Bool = false) -> UUID? {
        guard BrowserAvailabilitySettings.isEnabled() else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.openAndFocus result=blocked_browser_disabled " +
                "insertAtEnd=\(insertAtEnd ? 1 : 0) url=\(redactedDebugURL(url))"
            )
#endif
            return nil
        }

        let preferredProfileID =
            tabManager?.focusedBrowserPanel?.profileID
            ?? tabManager?.selectedWorkspace?.preferredBrowserProfileID
        guard let panelId = tabManager?.openBrowser(
            url: url,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        ) else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.openAndFocus result=open_failed insertAtEnd=\(insertAtEnd ? 1 : 0) " +
                "url=\(redactedDebugURL(url)) \(browserFocusStateSnapshot())"
            )
#endif
            return nil
        }
#if DEBUG
        cmuxDebugLog(
            "browser.focus.openAndFocus result=open_ok panel=\(panelId.uuidString.prefix(5)) " +
            "insertAtEnd=\(insertAtEnd ? 1 : 0) url=\(redactedDebugURL(url))"
        )
#endif
#if DEBUG
        let didFocus = focusBrowserAddressBar(panelId: panelId)
        cmuxDebugLog(
            "browser.focus.openAndFocus result=focus_request panel=\(panelId.uuidString.prefix(5)) " +
            "focused=\(didFocus ? 1 : 0) \(browserFocusStateSnapshot())"
        )
#else
        _ = focusBrowserAddressBar(panelId: panelId)
#endif
        return panelId
    }

    @discardableResult
    func openSidebarExtensionBrowser(from anchorView: NSView?, title: String) -> UUID? {
        // Defensive gate: the extensions browser is part of the experimental
        // Extensions feature. Its entry points are hidden while disabled, but
        // guard here too so no other path can open it.
        guard CmuxExtensionSidebarSelection().isEnabled else { return nil }
        let preferredWindow = anchorView?.window ?? shortcutRoutingActiveWindow
        let targetTabManager = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
        guard let workspace = targetTabManager?.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return nil
        }

        return workspace.newSidebarExtensionBrowserSurface(
            inPane: paneId,
            title: title,
            focus: true
        )?.id
    }

    // Relaxed from `private` to `internal` so the `WorkspaceCreationActionHosting`
    // witnesses in AppDelegate+WorkspaceCreationActionHosting.swift can reach it.
    func focusBrowserAddressBar(in panel: BrowserPanel) {
#if DEBUG
        let requestId = panel.requestAddressBarFocus(selectionIntent: .selectAll)
        cmuxDebugLog(
            "browser.focus.addressBar.request panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
        )
#else
        _ = panel.requestAddressBarFocus(selectionIntent: .selectAll)
#endif
        browserOmnibarFocusTracker.markFocused(panelId: panel.id)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.sticky panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8)) \(browserFocusStateSnapshot())"
        )
#endif
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
#if DEBUG
        cmuxDebugLog(
            "browser.focus.addressBar.notify panel=\(panel.id.uuidString.prefix(5)) " +
            "request=\(requestId.uuidString.prefix(8))"
        )
#endif
    }

    func focusedBrowserAddressBarPanelId() -> UUID? {
        browserOmnibarFocusTracker.focusedPanelId
    }

    func focusedBrowserOmnibarField(for event: NSEvent, in window: NSWindow?) -> OmnibarNativeTextField? {
        let panelId = focusedBrowserAddressBarPanelIdForShortcutEvent(event)
        return BrowserOmnibarNativeFieldRegistry.shared.omnibarField(panelId: panelId, in: window)
    }

    func clearBrowserAddressBarFocus(panelId: UUID, reason: String) {
        guard browserOmnibarFocusTracker.clearFocus(ifTrackedPanelId: panelId) else { return }
#if DEBUG
        cmuxDebugLog("addressBar CLEAR panelId=\(panelId.uuidString.prefix(8)) reason=\(reason)")
#endif
    }

    func focusedBrowserAddressBarPanelIdForShortcutEvent(_ event: NSEvent) -> UUID? {
        let shortcutWindow = resolvedShortcutEventWindow(event) ?? shortcutRoutingActiveWindow
        let shortcutResponder = shortcutWindow?.firstResponder
        let responderPanelId = isBrowserOmnibarResponder(shortcutResponder)
            ? BrowserOmnibarNativeFieldRegistry.shared.omnibarPanelId(for: shortcutResponder)
            : nil

        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            let candidatePanelId = responderPanelId ?? browserOmnibarFocusTracker.focusedPanelId
            guard let candidatePanelId else { return nil }
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(candidatePanelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_context event=\(event.cmuxKeyDescription)"
            )
#endif
            return nil
        }

        let intentPanelId = browserAddressBarIntentPanelId(in: context, window: shortcutWindow)
        guard let panelId = responderPanelId ?? browserOmnibarFocusTracker.focusedPanelId ?? intentPanelId else { return nil }

        guard let workspace = context.tabManager.selectedWorkspace else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_workspace event=\(event.cmuxKeyDescription)"
            )
#endif
            return nil
        }

        guard let panel = workspace.browserPanel(for: panelId) else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=panel_not_in_workspace workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(event.cmuxKeyDescription)"
            )
#endif
            return nil
        }

        if let responderPanelId {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(responderPanelId.uuidString.prefix(5)) " +
                "accepted=1 reason=omnibar_responder workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(event.cmuxKeyDescription)"
            )
#endif
            return responderPanelId
        }

        if intentPanelId == panelId, browserOmnibarFocusTracker.focusedPanelId == nil {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=1 reason=addressbar_intent workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(event.cmuxKeyDescription)"
            )
#endif
            return panelId
        }

        let liveOmnibarFieldExists = BrowserOmnibarNativeFieldRegistry.shared.omnibarField(panelId: panelId, in: shortcutWindow) != nil
        let trackedPanelMatchesShortcutResponder = browserPanel(panel, ownsShortcutResponder: shortcutResponder, in: shortcutWindow)
        let trackingContext = BrowserAddressBarTrackingContext(
            trackedPanelMatchesWebView: trackedPanelMatchesShortcutResponder,
            omnibarResponderActive: false,
            preferredFocusIntentIsAddressBar: panel.preferredFocusIntent == .addressBar,
            suppressesWebViewFocus: panel.shouldSuppressWebViewFocus(),
            pointerInitiatedWebFocus: false,
            liveOmnibarFieldExists: liveOmnibarFieldExists
        )
        if trackingContext.shouldPreserveAddressBarTrackingDuringWebViewFocus {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=1 reason=tracked_omnibar_field workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(event.cmuxKeyDescription)"
            )
#endif
            return panelId
        }

        if shouldPreserveBrowserAddressBarTrackingDuringTransientShortcutResponder(
            for: panel,
            responder: shortcutResponder,
            in: shortcutWindow,
            liveOmnibarFieldExists: liveOmnibarFieldExists
        ) {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=1 reason=transient_omnibar_focus workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(event.cmuxKeyDescription)"
            )
#endif
            return panelId
        }

#if DEBUG
        let focusedPanel = workspace.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        cmuxDebugLog(
            "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
            "accepted=0 reason=responder_not_omnibar responder=\(shortcutResponder.map { String(describing: type(of: $0)) } ?? "nil") " +
            "pending=\(panel.pendingAddressBarFocusRequestId != nil ? 1 : 0) focusedPanel=\(focusedPanel) " +
            "event=\(event.cmuxKeyDescription)"
        )
#endif
        return nil
    }

    private func shouldPreserveBrowserAddressBarTrackingDuringTransientShortcutResponder(
        for panel: BrowserPanel,
        responder: NSResponder?,
        in window: NSWindow?,
        liveOmnibarFieldExists: Bool
    ) -> Bool {
        guard browserOmnibarFocusTracker.focusedPanelId == panel.id else { return false }
        guard panel.preferredFocusIntent == .addressBar else { return false }
        guard panel.shouldSuppressWebViewFocus() ||
            liveOmnibarFieldExists ||
            panel.pendingAddressBarFocusRequestId != nil else {
            return false
        }

        guard let responder else { return true }
        if let window, responder === window {
            return true
        }
        if responder is NSWindow {
            return true
        }
        if BrowserOmnibarNativeFieldRegistry.shared.omnibarPanelId(for: responder) == panel.id {
            return true
        }
        if cmuxOwningGhosttyView(for: responder) != nil {
            return false
        }
        if responder is NSTextView || responder is NSTextField {
            return false
        }
        if let window, panel.ownedFocusIntent(for: responder, in: window) != nil {
            return false
        }
        return false
    }

    private func browserAddressBarIntentPanelId(
        in context: RegisteredMainWindow,
        window: NSWindow?
    ) -> UUID? {
        guard let workspace = context.tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let panel = workspace.browserPanel(for: focusedPanelId),
              panel.preferredFocusIntent == .addressBar,
              let field = BrowserOmnibarNativeFieldRegistry.shared.omnibarField(panelId: panel.id, in: window) else {
            return nil
        }

        guard panel.shouldSuppressWebViewFocus() || field.currentEditor() != nil else {
            return nil
        }
        return panel.id
    }

    private func browserPanel(
        _ panel: BrowserPanel,
        ownsShortcutResponder responder: NSResponder?,
        in window: NSWindow?
    ) -> Bool {
        guard let responder, let window else { return false }
        if BrowserOmnibarNativeFieldRegistry.shared.omnibarPanelId(for: responder) == panel.id {
            return true
        }
        if case .browser(.webView)? = panel.ownedFocusIntent(for: responder, in: window) {
            return true
        }
        return false
    }

    private func browserOmnibarOwnerView(for responder: NSResponder?) -> NSView? {
        guard let responder else { return nil }

        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           let delegateView = textView.delegate as? NSView,
           delegateView.identifier == browserOmnibarTextFieldIdentifier {
            return delegateView
        }

        let ownerView = keyRoutingOwnerView(for: responder)
        guard ownerView?.identifier == browserOmnibarTextFieldIdentifier else { return nil }
        return ownerView
    }

    private func isBrowserOmnibarResponder(_ responder: NSResponder?) -> Bool {
        guard let ownerView = browserOmnibarOwnerView(for: responder) else { return false }

        if let fieldEditor = responder as? NSTextView,
           fieldEditor.isFieldEditor {
            return (ownerView as? NSTextField)?.currentEditor() === fieldEditor
        }

        return true
    }

    private func shouldPreserveBrowserAddressBarTracking(
        for panel: BrowserPanel,
        trackedPanelMatchesWebView: Bool,
        pointerInitiatedWebFocus: Bool = false,
        in window: NSWindow? = nil
    ) -> Bool {
        guard browserOmnibarFocusTracker.focusedPanelId == panel.id else { return false }
        let resolvedWindow = window ?? panel.webView.window
        let trackingContext = BrowserAddressBarTrackingContext(
            trackedPanelMatchesWebView: trackedPanelMatchesWebView,
            omnibarResponderActive: isBrowserOmnibarResponder(resolvedWindow?.firstResponder),
            preferredFocusIntentIsAddressBar: panel.preferredFocusIntent == .addressBar,
            suppressesWebViewFocus: panel.shouldSuppressWebViewFocus(),
            pointerInitiatedWebFocus: pointerInitiatedWebFocus,
            liveOmnibarFieldExists: BrowserOmnibarNativeFieldRegistry.shared.omnibarField(panelId: panel.id, in: resolvedWindow) != nil
        )
        return trackingContext.shouldPreserveAddressBarTrackingDuringWebViewFocus
    }

    @discardableResult
    func requestBrowserAddressBarFocus(panelId: UUID) -> Bool {
        focusBrowserAddressBar(panelId: panelId)
    }

    private func controlOmnibarSelectionDelta(
        hasFocusedAddressBar: Bool,
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Int? {
        flags.browserOmnibarSelectionDeltaForControlNavigation(
            hasFocusedAddressBar: hasFocusedAddressBar,
            chars: chars
        )
    }

    private func dispatchBrowserOmnibarSelectionMove(panelId: UUID, delta: Int) {
        browserOmnibarFocusTracker.selectionRepeat.dispatchSelectionMove(panelID: panelId, delta: delta)
    }

    private func startBrowserOmnibarSelectionRepeatIfNeeded(panelId: UUID, keyCode: UInt16, delta: Int) {
        browserOmnibarFocusTracker.selectionRepeat.startRepeatIfNeeded(panelID: panelId, keyCode: keyCode, delta: delta)
    }

    private func stopBrowserOmnibarSelectionRepeat() {
        browserOmnibarFocusTracker.selectionRepeat.stopRepeat()
    }

    private func handleBrowserOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        switch event.type {
        case .keyUp:
            browserOmnibarFocusTracker.selectionRepeat.noteKeyUp(keyCode: event.keyCode)
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            browserOmnibarFocusTracker.selectionRepeat.noteFlagsChanged(
                shouldContinue: flags.browserOmnibarShouldContinueControlNavigationRepeat,
                flagsRawValue: flags.rawValue
            )
        default:
            break
        }
    }

#if DEBUG
    private func developerToolsShortcutProbeKind(event: NSEvent) -> String? {
        guard event.type == .keyDown else { return nil }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
            return "toggle.configured"
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
            return "console.configured"
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option] {
            if chars == "i" || event.keyCode == 34 {
                return "toggle.literal"
            }
            if chars == "c" || event.keyCode == 8 {
                return "console.literal"
            }
        }
        return nil
    }

    private func logDeveloperToolsShortcutSnapshot(
        phase: String,
        event: NSEvent? = nil,
        didHandle: Bool? = nil
    ) {
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let eventDescription = event.map(\.cmuxKeyDescription) ?? "none"
        if let browser = tabManager?.focusedBrowserPanel {
            var line =
                "browser.devtools shortcut=\(phase) panel=\(browser.id.uuidString.prefix(5)) " +
                "\(browser.debugDeveloperToolsStateSummary()) \(browser.debugDeveloperToolsGeometrySummary()) " +
                "keyWin=\(keyWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
            if let didHandle {
                line += " handled=\(didHandle ? 1 : 0)"
            }
            cmuxDebugLog(line)
            return
        }
        var line =
            "browser.devtools shortcut=\(phase) panel=nil keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
        if let didHandle {
            line += " handled=\(didHandle ? 1 : 0)"
        }
        cmuxDebugLog(line)
    }
#endif

    @discardableResult
    func performSplitShortcut(direction: SplitDirection, preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow)
        _ = synchronizeActiveMainWindowContext(preferredWindow: targetWindow)

        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }

        #if DEBUG
        let keyWindow = shortcutRoutingKeyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let firstResponderWindow: Int = {
            if let v = firstResponder as? NSView {
                return v.window?.windowNumber ?? -1
            }
            if let w = firstResponder as? NSWindow {
                return w.windowNumber
            }
            return -1
        }()
        let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
        if let browser = tabManager?.focusedBrowserPanel {
            let webWindow = browser.webView.window?.windowNumber ?? -1
            let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            cmuxDebugLog("split.shortcut dir=\(directionLabel) pre panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
        } else {
            cmuxDebugLog("split.shortcut dir=\(directionLabel) pre panel=nil \(splitContext)")
        }
        #endif

        let didCreateSplit: Bool = {
            if let terminalContext {
                return terminalContext.tabManager.createSplit(
                    tabId: terminalContext.workspaceId,
                    surfaceId: terminalContext.panelId,
                    direction: direction
                ) != nil
            }
            return tabManager?.createSplit(direction: direction) != nil
        }()
#if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let keyWindow = self?.shortcutRoutingKeyWindow
            let firstResponder = keyWindow?.firstResponder
            let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let firstResponderWindow: Int = {
                if let v = firstResponder as? NSView {
                    return v.window?.windowNumber ?? -1
                }
                if let w = firstResponder as? NSWindow {
                    return w.windowNumber
                }
                return -1
            }()
            let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
            if let browser = self?.tabManager?.focusedBrowserPanel {
                let webWindow = browser.webView.window?.windowNumber ?? -1
                let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                cmuxDebugLog("split.shortcut dir=\(directionLabel) post panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
            } else {
                cmuxDebugLog("split.shortcut dir=\(directionLabel) post panel=nil \(splitContext)")
            }
        }
        recordGotoSplitSplitIfNeeded(direction: direction)
#endif
        return didCreateSplit
    }

    /// Allow AppKit-backed browser surfaces (WKWebView) to route non-menu shortcuts
    /// through the same app-level shortcut handler used by the local key monitor.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool {
        handleConfiguredShortcutKeyEquivalent(event)
    }

    /// Route AppKit key-equivalent fallbacks through the same configured shortcut
    /// dispatcher as the local key monitor before any stale menu item can run.
    @discardableResult
    func handleConfiguredShortcutKeyEquivalent(_ event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    /// Route numbered workspace/surface key-equivalent fallbacks through the same
    /// app shortcut dispatcher before terminal-owned non-Command keys go to Ghostty.
    @discardableResult
    func handleRoutableNumberedShortcutKeyEquivalent(_ event: NSEvent) -> Bool {
        guard eventCouldMatchNumberedShortcutDigit(event) else {
            return false
        }
        guard routableNumberedConfiguredShortcutDigit(event: event, action: .selectWorkspaceByNumber) != nil ||
            routableNumberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) != nil else {
            return false
        }
        return handleCustomShortcut(event: event)
    }

    /// WebKit can consume the configured Find shortcut as a browser find key equivalent before SwiftUI
    /// command actions run. Keep this pre-menu route narrow so normal menu-backed
    /// browser shortcuts such as New Workspace, Close Tab, and Reload Page still use AppKit.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalentBeforeMainMenu(_ event: NSEvent) -> Bool {
        if matchConfiguredShortcut(event: event, action: .find) {
            let shortcutWindow = resolvedShortcutEventWindow(event)
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: tabManager, window: shortcutWindow ?? shortcutRoutingKeyWindow); return performFindShortcutInActiveMainWindow(preferredWindow: shortcutWindow)
        }
        if matchConfiguredShortcut(event: event, action: .findInDirectory) {
            return focusFileSearchInActiveMainWindow(preferredWindow: resolvedShortcutEventWindow(event))
        }
        return false
    }

    @discardableResult
    func requestRenameWorkspaceViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        requestCommandPaletteRenameWorkspace(
            preferredWindow: targetWindow,
            source: "shortcut.renameWorkspace"
        )
        return true
    }

    @discardableResult
    func handleToggleFocusedWorkspaceGroupCollapsedShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let resolvedTabManager: TabManager? = contextForMainWindow(targetWindow)?.tabManager ?? self.tabManager
        guard let tabManager = resolvedTabManager else { return false }
        guard let focusedId = tabManager.selectedTabId,
              let groupId = tabManager.tabs.first(where: { $0.id == focusedId })?.groupId else {
            // Don't consume the event when the focused workspace isn't in a
            // group — let the matched chord propagate (no React Grab
            // collision here, but stay consistent with the group-create
            // shortcut's fall-through policy).
            return false
        }
        tabManager.toggleWorkspaceGroupCollapsed(groupId: groupId)
        return true
    }

    /// Create a new empty workspace group (anchor only, no children). Backs the
    /// New Workspace Group menu item and its configured shortcut. Resolves the
    /// TabManager for the preferred/key/main window so multi-window users get the
    /// group in the window they were looking at. Declines when the focused
    /// workspace is a remote tmux mirror (group creation isn't meaningful there).
    @discardableResult
    func createEmptyWorkspaceGroup(tabManager explicitTabManager: TabManager? = nil, preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let resolvedTabs: TabManager? = explicitTabManager ?? contextForMainWindow(targetWindow)?.tabManager ?? self.tabManager
        guard let tabs = resolvedTabs, tabs.selectedTab?.isRemoteTmuxMirror != true else { return false }
        return tabs.createWorkspaceGroup(name: "") != nil
    }

    @discardableResult
    func handleGroupSelectedWorkspacesShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        // Resolve the TabManager for the preferred/key/main window first so
        // multi-window users get the group created in the window they were
        // looking at. Fall back to the app-level tabManager only if no window
        // context resolves.
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let resolvedTabManager: TabManager? = contextForMainWindow(targetWindow)?.tabManager ?? self.tabManager
        guard let tabManager = resolvedTabManager else { return false }
        let selectedSet = tabManager.sidebarSelectedWorkspaceIds
        // sidebarSelectedWorkspaceIds is a Set; sort by tabs[] order so the
        // anchor is placed before the first sidebar-visible selected workspace
        // (createWorkspaceGroup uses the first child to position the anchor).
        let orderedSelectedIds: [UUID] = selectedSet.isEmpty
            ? []
            : tabManager.tabs.compactMap { selectedSet.contains($0.id) ? $0.id : nil }
        // Only consume the shortcut when there's an explicit sidebar
        // multi-selection. Anything ≤ 1 falls through so ⌘⇧G keeps working as
        // React Grab's default in browser/terminal contexts. A single-tab
        // group can still be created via right-click → New Group from
        // Workspace. `sidebarSelectedWorkspaceIds` is normally synced to the
        // focused workspace (clearSidebarMultiSelection sets it to a
        // singleton after keyboard nav), so the singleton case must be
        // treated the same as "no selection."
        guard orderedSelectedIds.count >= 2 else { return false }
        let candidateIds: [UUID] = orderedSelectedIds
        // Match the workspace context-menu eligibility filter so the shortcut
        // doesn't silently create an anchor-only group when every selected
        // target is already an existing group's anchor.
        let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleIds: [UUID] = candidateIds.filter { id in
            tabManager.tabs.contains(where: { $0.id == id }) && !existingAnchorIds.contains(id)
        }
        guard eligibleIds.count >= 2 else {
            // Don't consume the event — let it propagate to the next handler
            // (e.g. toggleReactGrab on the default Cmd+Shift+G binding) so
            // the user gets the next-best action instead of a dead key. The
            // shortcut contract is "multi-select then ⌘⇧G"; single-workspace
            // groups are only created from the right-click context menu, so
            // a 2-row sidebar selection where only one survives the
            // pinned/anchor filter should also fall through.
            return false
        }
        // No name prompt: TabManager auto-names ("Group N"). Rename via the
        // header context menu.
        tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: eligibleIds)
        return true
    }

    @discardableResult
    func requestEditWorkspaceDescriptionViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
#if DEBUG
        cmuxDebugLog(
            "shortcut.editWorkspaceDescription request target={\(debugWindowToken(targetWindow))} " +
            "fr=\(targetWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        )
#endif
        requestCommandPaletteEditWorkspaceDescription(
            preferredWindow: targetWindow,
            source: "shortcut.editWorkspaceDescription"
        )
        return true
    }

#if DEBUG
    // Debug/test hook: allow socket-driven shortcut simulation to reuse the same shortcut routing
    // logic as the local NSEvent monitor, without relying on AppKit event monitor behavior for
    // synthetic NSEvents.
    func debugHandleCustomShortcut(event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

    // Debug/test hook: mirrors local monitor routing (keyDown + keyUp lifecycle).
    func debugHandleShortcutMonitorEvent(event: NSEvent) -> Bool {
        if event.type == .systemDefined {
            return false
        }
        if event.type == .keyDown {
            return handleCustomShortcut(event: event)
        }
        handleBrowserOmnibarSelectionRepeatLifecycleEvent(event)
        return clearEscapeSuppressionForKeyUp(event: event, consumeIfSuppressed: true)
    }

    func debugMatchesConfiguredShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Bool {
        matchConfiguredShortcut(event: event, action: action)
    }

    func debugMarkCommandPaletteOpenPending(window: NSWindow) {
        markCommandPaletteOpenRequested(for: window)
    }

    @discardableResult
    func debugSetCommandPalettePendingOpenAge(window: NSWindow, age: TimeInterval) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        commandPalettePresentation.setPendingOpenAge(windowId, age: age)
        return true
    }

    // Test hook: remap a window context under a detached window key so direct
    // ObjectIdentifier(window) lookups fail and fallback logic is exercised.
    @discardableResult
    func debugInjectWindowContextKeyMismatch(windowId: UUID) -> Bool {
        guard let context = registeredMainWindow(forWindowId: windowId),
              (context.window ?? windowForMainWindowId(windowId)) != nil else {
            return false
        }

        let detachedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        debugDetachedContextWindows.append(detachedWindow)

        // Remap the window's identity in the coordinator under the detached
        // NSWindow so `windowCoordinator.id(for: realWindow)` (the direct
        // window-object lookup) fails and the windowId/identifier fallback in
        // `contextForMainTerminalWindow` is exercised. The per-domain slices
        // (tab manager, focus controller, …) stay keyed by `windowId`, exactly
        // as the real window owns them.
        windowCoordinator.register(detachedWindow, id: WindowID(windowId))
        return true
    }
#endif

    private func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview, titled: title) {
                return found
            }
        }
        return nil
    }

    private func findStaticText(in view: NSView, equals text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text {
            return true
        }
        for subview in view.subviews {
            if findStaticText(in: subview, equals: text) {
                return true
            }
        }
        return false
    }

    @discardableResult
    func handleBrowserPopupCloseShortcutKeyEquivalent(event: NSEvent, popupWindow: NSWindow) -> Bool {
        guard event.type == .keyDown else {
            clearConfiguredShortcutChordState()
            return false
        }
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive else {
            clearConfiguredShortcutChordState()
            return false
        }

        let configuredShortcutEventWindowNumber = configuredShortcutChordWindowNumber(for: event)
        shortcutChordCoordinator.prepareForEvent(windowNumber: configuredShortcutEventWindowNumber)
        defer {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
            clearShortcutEventFocusContextCache(for: event)
        }

        if matchConfiguredShortcut(event: event, action: .closeTab) {
#if DEBUG
            cmuxDebugLog("popup.panel.closeShortcut close")
#endif
            popupWindow.performClose(nil)
            return true
        }
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           armConfiguredShortcutChordIfNeeded(event: event, actions: [.closeTab]) {
#if DEBUG
            cmuxDebugLog("popup.panel.closeShortcut armChord")
#endif
            return true
        }
        return false
    }

    private func matchConfiguredShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        // The chord-aware match decision lives on `StoredShortcut` in
        // CmuxShortcuts; this witness only supplies the per-stroke matcher that
        // reads the live `NSEvent` (which cannot leave the app target).
        shortcut.matchesConfigured(
            activeChordPrefix: activeConfiguredShortcutChordPrefixForCurrentEvent
        ) { matchShortcutStroke(event: event, stroke: $0) }
    }

    func matchConfiguredShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        if !shortcutWhenClauseAllows(action: action, event: event) { return false }
        return matchConfiguredShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: action))
    }

    func matchesSavedLayoutSaveShortcut(event: NSEvent) -> Bool {
        matchConfiguredShortcut(event: event, action: .saveLayoutTemplate)
    }

    /// Whether `action`'s effective `when` clause (its `shortcuts.when` override,
    /// or its built-in context default) is satisfied by the event's focus state.
    /// Gates every focus-scoped shortcut, including the numbered workspace/surface
    /// handlers that previously ignored context (issue #5189).
    func shortcutWhenClauseAllows(action: KeyboardShortcutSettings.Action, event: NSEvent) -> Bool {
        KeyboardShortcutSettings.effectiveWhenClause(for: action)
            .evaluate(shortcutEventFocusContext(event).shortcutContext)
    }

    /// Resolves a right-sidebar mode shortcut after applying the action's
    /// effective `when` clause.
    func rightSidebarModeShortcut(for event: NSEvent) -> RightSidebarMode? {
        RightSidebarMode.modeShortcut(for: event) { [self] action in
            shortcutWhenClauseAllows(action: action, event: event)
        }
    }

    fileprivate func shouldForwardBrowserSurfaceShortcutToTerminal(_ event: NSEvent) -> Bool {
        return KeyboardShortcutSettings.Action.allCases.contains {
            $0.shortcutContext.forwardsMenuEquivalentToFocusedTerminal &&
                !$0.isBrowserContentShortcut &&
                matchConfiguredShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: $0))
        }
    }

    private func numberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        // The chord-aware numbered-digit decision lives on `StoredShortcut` in
        // CmuxShortcuts; this witness supplies the per-stroke digit resolver that
        // reads the live `NSEvent`.
        KeyboardShortcutSettings.shortcut(for: action).numberedConfiguredDigit(
            activeChordPrefix: activeConfiguredShortcutChordPrefixForCurrentEvent
        ) { numberedShortcutDigit(event: event, stroke: $0) }
    }

    /// Resolves the configured numbered-shortcut digit for `action` only when the
    /// action's effective `when` clause allows routing for this event. Rebinding a
    /// numbered workspace/surface shortcut (including Option-modified digits) has to
    /// flow through the same gate the terminal-key fallback consults, so both the
    /// per-keystroke dispatch and the key-equivalent fallback share this resolver.
    private func routableNumberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        if let digit = numberedConfiguredShortcutDigit(event: event, action: action),
           shortcutWhenClauseAllows(action: action, event: event) {
            return digit
        }
        return nil
    }

    /// Wraps the printable-Option-text bypass so a rebound numbered
    /// workspace/surface shortcut isn't stolen by the bypass before it can be
    /// routed. Only the app routing layer consults this; the low-level
    /// `StoredShortcut.matches(event:)` matcher still uses the plain bypass.
    fileprivate func shouldBypassPrintableOptionTextForShortcutRouting(event: NSEvent) -> Bool {
        guard shortcutRoutingShouldBypassForPrintableOptionText(event: event) else {
            return false
        }

        if routableNumberedConfiguredShortcutDigit(event: event, action: .selectWorkspaceByNumber) != nil {
            return false
        }

        if routableNumberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) != nil {
            return false
        }

        return true
    }

    /// The TabManager a numbered workspace/surface shortcut should act on: the
    /// preferred main window's manager for this event, falling back to the
    /// app-level manager. Matches the window-routing idiom the rest of the
    /// shortcut dispatch uses.
    private func tabManagerForNumberedShortcut(event: NSEvent) -> TabManager? {
        preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
    }

    private func matchConfiguredDirectionalShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        guard shortcutWhenClauseAllows(action: action, event: event) else {
            return false
        }
        // Same chord-aware match decision as `matchConfiguredShortcut`; the
        // per-stroke matcher here is the directional (arrow-glyph) comparison,
        // which reads the live `NSEvent` and layout provider app-side.
        return KeyboardShortcutSettings.shortcut(for: action).matchesConfigured(
            activeChordPrefix: activeConfiguredShortcutChordPrefixForCurrentEvent
        ) { stroke in
            stroke.matchesDirectionalShortcut(
                event: event,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode,
                layoutCharacterProvider: shortcutCoordinator.layoutCharacter(forKeyCode:modifierFlags:)
            )
        }
    }

    private func configuredShortcutChordWindowNumber(for event: NSEvent) -> Int? {
        if let window = mainWindowForShortcutEvent(event) {
            return window.windowNumber
        }
        if let window = event.window {
            return window.windowNumber
        }
        return event.windowNumber > 0 ? event.windowNumber : nil
    }

    func armConfiguredShortcutChordIfNeeded(
        event: NSEvent,
        actions: [KeyboardShortcutSettings.Action],
        shortcuts: [StoredShortcut] = []
    ) -> Bool {
        let configuredShortcuts = actions.map {
            KeyboardShortcutSettings.shortcut(for: $0)
        } + shortcuts
        return shortcutChordCoordinator.armIfNeeded(
            candidates: configuredShortcuts,
            windowNumber: configuredShortcutChordWindowNumber(for: event),
            isChord: { $0.hasChord },
            firstStroke: { $0.firstStroke },
            firstStrokeMatches: { matchShortcutStroke(event: event, stroke: $0) }
        )
    }

    func configuredCmuxShortcutActions(
        for context: RegisteredMainWindow?
    ) -> [CmuxResolvedConfigAction] {
        guard let context else { return [] }
        return windowRegistry.context(for: WindowID(context.windowId))?.configStore?.shortcutActions() ?? []
    }

    private func handleConfiguredCmuxShortcut(
        event: NSEvent,
        actions: [CmuxResolvedConfigAction],
        context: RegisteredMainWindow?
    ) -> Bool {
        for action in actions {
            guard let shortcut = action.shortcut,
                  matchConfiguredShortcut(event: event, shortcut: shortcut) else {
                continue
            }
            return executeConfiguredCmuxActionShortcut(
                action,
                event: event,
                context: context
            )
        }
        return false
    }

    private func executeConfiguredCmuxActionShortcut(
        _ action: CmuxResolvedConfigAction,
        event: NSEvent,
        context: RegisteredMainWindow?
    ) -> Bool {
        guard let context else { return false }
        return executeConfiguredCmuxAction(
            action,
            context: context,
            preferredWindow: event.window ?? shortcutRoutingActiveWindow
        )
    }

    /// Public entry for the sidebar group `+` right-click context menu: runs a
    /// resolved configured action and, on success for "new workspace" style
    /// builtIns, joins the newly-created workspace to the given group.
    @discardableResult
    func runWorkspaceGroupConfiguredAction(
        _ action: CmuxResolvedConfigAction,
        tabManager: TabManager,
        groupId: UUID
    ) -> Bool {
        guard let context = registeredMainWindow(forManager: tabManager) else {
            return false
        }
        let anchorId = tabManager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId
        let groupPlacement: WorkspaceGroupNewPlacement = {
            let cwd = anchorId.flatMap { id in
                tabManager.tabs.first(where: { $0.id == id })?.currentDirectory
            }
            let configured = windowRegistry.context(for: WindowID(context.windowId))?.configStore?.resolveWorkspaceGroupConfig(forCwd: cwd)?.newWorkspacePlacement
            return configured
                ?? UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
        }()
        // Short-circuit the built-in `newWorkspace` action: it must go through
        // createWorkspaceInGroup so the new workspace inherits the anchor's
        // cwd and honors the group's configured placement, matching
        // the bare `+` button. The generic executor below uses addWorkspace()
        // which skips both behaviors.
        if case .builtIn(.newWorkspace) = action.action {
            return tabManager.createWorkspaceInGroup(
                groupId: groupId,
                placement: groupPlacement,
                referenceWorkspaceId: anchorId
            ) != nil
        }
        // Snapshot tab ids BEFORE the action fires so the onExecuted callback
        // (which runs after any confirmation/authorization flow completes) can
        // diff against the pre-action state and join the newly-created
        // workspace to the group. The previous post-call diff missed actions
        // gated on a first-run trust prompt because the workspace doesn't
        // exist until the user grants permission.
        let beforeIds = Set(tabManager.tabs.map(\.id))
        // Group menu actions should run as if the anchor were the active
        // workspace: the executor derives the new workspace's cwd from
        // `context.tabManager.selectedWorkspace`, and a group menu item is
        // conceptually scoped to the anchor's cwd (that's how it was matched
        // in `workspaceGroups.byCwd` in the first place). Temporarily switch
        // selection to the anchor for the duration of the action; if the user
        // had a different workspace focused before, restore it once the
        // action's onExecuted fires. Skipped when no action workspace was
        // created so we don't strand selection on the anchor.
        let previousSelectedId = tabManager.selectedTabId
        if let anchorId, anchorId != previousSelectedId,
           tabManager.tabs.contains(where: { $0.id == anchorId }) {
            tabManager.selectedTabId = anchorId
        }
        var asyncObserverId: UUID?
        let workspaceGroupJoinCoordinator = self.workspaceGroupJoinCoordinator
        let onExecuted: () -> Void = { [weak tabManager, groupId, beforeIds, previousSelectedId, anchorId, groupPlacement, action, workspaceGroupJoinCoordinator] in
            guard let tabManager else { return }
            let afterIds = tabManager.tabs.map(\.id)
            var newlyCreatedId: UUID?
            for id in afterIds where !beforeIds.contains(id) {
                tabManager.addWorkspaceToGroup(
                    workspaceId: id,
                    groupId: groupId,
                    placement: groupPlacement,
                    referenceWorkspaceId: anchorId
                )
                newlyCreatedId = id
                break
            }
            // cloudVM launches a `cmux vm new` process and returns before the
            // workspace appears in tabs[]. The synchronous diff above misses
            // it, so watch the tab list while the process is running. Process
            // completion also reports the created workspace UUID as an exact
            // fallback.
            if newlyCreatedId == nil, case .builtIn(.cloudVM) = action.action {
                asyncObserverId = workspaceGroupJoinCoordinator.install(
                    host: tabManager,
                    groupId: groupId,
                    knownIds: Set(afterIds),
                    placement: groupPlacement,
                    referenceWorkspaceId: anchorId
                )
            }
            // Restore the prior selection if the action didn't create a new
            // workspace (the gesture wasn't "go work in the new one") and
            // the previous selection still exists. When a new workspace was
            // created, leave it focused — that matches what the equivalent
            // bare `+` button does.
            if newlyCreatedId == nil,
               let previousSelectedId,
               previousSelectedId != tabManager.selectedTabId,
               tabManager.tabs.contains(where: { $0.id == previousSelectedId }) {
                tabManager.selectedTabId = previousSelectedId
            }
        }
        let onCloudVMCompletion: (CloudVMActionCompletion) -> Void = { [weak tabManager, workspaceGroupJoinCoordinator] completion in
            guard let tabManager, let asyncObserverId else { return }
            workspaceGroupJoinCoordinator.finishPending(
                host: tabManager,
                observerId: asyncObserverId,
                workspaceId: completion.succeeded ? completion.workspaceId : nil
            )
        }
        let didRun = executeConfiguredCmuxAction(
            action,
            context: context,
            preferredWindow: resolvedWindow(for: context),
            onExecuted: onExecuted,
            onCloudVMCompletion: onCloudVMCompletion
        )
        // executeConfiguredCmuxAction returns false when the action couldn't
        // start at all (unresolved action ref, missing target terminal, etc.).
        // In that case onExecuted will never fire, so restore the prior
        // selection here. The trust-prompt-cancelled window (action returns
        // true but the user later cancels) leaves selection on the anchor
        // until the user clicks something else; tradeoff documented at the
        // call site.
        if !didRun,
           let previousSelectedId,
           previousSelectedId != tabManager.selectedTabId,
           tabManager.tabs.contains(where: { $0.id == previousSelectedId }) {
            tabManager.selectedTabId = previousSelectedId
        }
        return didRun
    }

    func executeConfiguredCmuxAction(
        _ action: CmuxResolvedConfigAction,
        context: RegisteredMainWindow,
        preferredWindow: NSWindow? = nil,
        onExecuted: (() -> Void)? = nil,
        onCloudVMCompletion: ((CloudVMActionCompletion) -> Void)? = nil
    ) -> Bool {
        switch action.action {
        case .builtIn(let builtIn):
            switch builtIn {
            case .newWorkspace:
                context.tabManager.addWorkspace()
                onExecuted?()
                return true
            case .newAgentChat:
                return performConfiguredNewAgentChatAction(
                    context: context,
                    preferredWindow: preferredWindow,
                    onExecuted: onExecuted
                )
            case .cloudVM:
                let didStart = performCloudVMAction(
                    tabManager: context.tabManager,
                    preferredWindow: resolvedWindow(for: context) ?? preferredWindow,
                    debugSource: "configured.cmux.cloudvm",
                    onCompletion: onCloudVMCompletion
                )
                if didStart { onExecuted?() }
                return didStart
            case .mobileConnect:
                MobilePairingWindowController.shared.show()
                onExecuted?()
                return true
            case .newTerminal:
                context.tabManager.newSurface()
                onExecuted?()
                return true
            case .newBrowser:
                let previousTabManager = tabManager
                tabManager = context.tabManager
                defer { tabManager = previousTabManager }
                guard openBrowserAndFocusAddressBar(insertAtEnd: true) != nil else {
                    return false
                }
                onExecuted?()
                return true
            case .splitRight:
                if shouldSuppressSplitShortcutForTransientTerminalFocusState(
                    direction: .right,
                    tabManager: context.tabManager
                ) {
                    return true
                }
                let didSplit = performSplitShortcut(
                    direction: .right,
                    preferredWindow: preferredWindow ?? shortcutRoutingActiveWindow
                )
                if didSplit { onExecuted?() }
                return didSplit
            case .splitDown:
                if shouldSuppressSplitShortcutForTransientTerminalFocusState(
                    direction: .down,
                    tabManager: context.tabManager
                ) {
                    return true
                }
                let didSplit = performSplitShortcut(
                    direction: .down,
                    preferredWindow: preferredWindow ?? shortcutRoutingActiveWindow
                )
                if didSplit { onExecuted?() }
                return didSplit
            @unknown default:
                return false
            }
        case .command, .agent, .workspaceCommand, .workspace:
            guard let cmuxConfigStore = windowRegistry.context(for: WindowID(context.windowId))?.configStore else {
                return false
            }
            let rawCwd = context.tabManager.selectedWorkspace?.currentDirectory
            let baseCwd = (rawCwd?.isEmpty == false) ? rawCwd!
                : FileManager.default.homeDirectoryForCurrentUser.path
            return CmuxConfigExecutor.execute(
                action: action,
                commands: cmuxConfigStore.loadedCommands,
                commandSourcePaths: cmuxConfigStore.commandSourcePaths,
                tabManager: context.tabManager,
                baseCwd: baseCwd,
                globalConfigPath: cmuxConfigStore.globalConfigPath,
                presentingWindow: preferredWindow,
                onExecuted: onExecuted
            )
        case .actionReference:
            return false
        }
    }

    /// Match a shortcut stroke against an event, handling normal keys.
    func matchShortcutStroke(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        stroke.matches(event: event, layoutCharacterProvider: shortcutLayoutCharacterProvider)
    }

    private func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        shortcut.matches(event: event, layoutCharacterProvider: shortcutCoordinator.layoutCharacter(forKeyCode:modifierFlags:))
    }

    private func matchesKeyboardShortcutEvent(
        _ event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut
    ) -> Bool {
        // The numbered-vs-full match decision lives on `StoredShortcut` in
        // CmuxShortcuts; this witness supplies the two live-event closures.
        shortcut.matchesKeyboardShortcutEvent(
            usesNumberedDigitMatching: action.usesNumberedDigitMatching,
            numberedDigit: { numberedShortcutDigit(event: event, shortcut: shortcut) },
            fullMatch: { matchShortcut(event: event, shortcut: shortcut) }
        )
    }

    func shouldSuppressStaleCmuxMenuShortcut(event: NSEvent) -> Bool {
        // Witness for AppMenuCoordinator.shouldSuppressStaleMenuShortcut: assemble
        // the live-state projection here (the NSEvent, KeyboardShortcutSettings
        // reads, recorder activity, and key-window/modal/sheet reads cannot leave
        // the app target while KeyboardShortcutSettings lives in Sources/), then
        // delegate the boolean branching policy across the seam.
        let isKeyDown = event.type == .keyDown
        // While a Settings recorder is armed, every keystroke must reach it to be
        // captured — including a remapped-away default like the old ⌘1 the user is
        // trying to record. Suppressing the stale menu shortcut here would consume
        // that keystroke before `RecorderHostButton.performKeyEquivalent` sees it,
        // so stand down for both recorders (issue #5189).
        let anyRecorderActive = KeyboardShortcutRecorderActivity.isAnyRecorderActive
            || RecorderHostButton.isActivelyRecording
        let keyWindow = shortcutRoutingKeyWindow
        let isPanelOrModalOrSheet = event.window is NSPanel
            || keyWindow is NSPanel
            || NSApp.modalWindow != nil
            || keyWindow?.attachedSheet != nil
        let hasCommandFlag = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
            .contains(.command)

        // The per-action allCases scans only change the verdict once the cheap
        // gates above pass, so skip them otherwise to keep the legacy per-event
        // fast path (no KeyboardShortcutSettings.Action scan on non-command
        // keystrokes / non-key events). The coordinator re-derives the same
        // verdict from the full context.
        let staleDefaultActions: [StaleMenuShortcutContext.StaleDefaultAction]
        let anyCurrentShortcutMatchesEvent: Bool
        if isKeyDown, !anyRecorderActive, !isPanelOrModalOrSheet, hasCommandFlag {
            staleDefaultActions = KeyboardShortcutSettings.Action.allCases.compactMap { action in
                guard action.isMenuBacked,
                      matchesKeyboardShortcutEvent(event, action: action, shortcut: action.defaultShortcut)
                else { return nil }
                return StaleMenuShortcutContext.StaleDefaultAction(
                    isCloseAction: action.isCloseAction,
                    currentShortcutMatchesEvent: currentShortcutMatchesKeyboardShortcutEvent(event, action: action)
                )
            }
            anyCurrentShortcutMatchesEvent = KeyboardShortcutSettings.Action.allCases.contains { action in
                currentShortcutMatchesKeyboardShortcutEvent(event, action: action)
            }
        } else {
            staleDefaultActions = []
            anyCurrentShortcutMatchesEvent = false
        }

        return appMenuCoordinator.shouldSuppressStaleMenuShortcut(
            context: StaleMenuShortcutContext(
                isKeyDown: isKeyDown,
                anyRecorderActive: anyRecorderActive,
                isPanelOrModalOrSheet: isPanelOrModalOrSheet,
                hasCommandFlag: hasCommandFlag,
                staleDefaultActions: staleDefaultActions,
                anyCurrentShortcutMatchesEvent: anyCurrentShortcutMatchesEvent
            )
        )
    }

    private func currentShortcutMatchesKeyboardShortcutEvent(
        _ event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Bool {
        let currentShortcut = KeyboardShortcutSettings.shortcut(for: action)
        if action.usesNumberedDigitMatching {
            return numberedShortcutDigit(event: event, shortcut: currentShortcut) != nil
        }
        return matchesKeyboardShortcutEvent(event, action: action, shortcut: currentShortcut)
    }

    private func numberedShortcutDigit(event: NSEvent, stroke: ShortcutStroke) -> Int? {
        shortcutCoordinator.numberedShortcutDigit(
            eventKeyCode: event.keyCode,
            eventCharactersIgnoringModifiers: event.charactersIgnoringModifiers,
            eventModifierFlags: event.modifierFlags,
            requireModifierFlags: stroke.modifierFlags
        )
    }

    private func numberedShortcutDigit(event: NSEvent, shortcut: StoredShortcut) -> Int? {
        // The non-chord first-stroke digit decision lives on `StoredShortcut` in
        // CmuxShortcuts; this witness supplies the per-stroke digit resolver.
        shortcut.firstStrokeNumberedDigit { numberedShortcutDigit(event: event, stroke: $0) }
    }

    /// Cheap, modifier-agnostic preflight: could this event's key code or printed
    /// characters resolve to a numbered digit (1–9) at all? Keeps the numbered
    /// key-equivalent fallback from doing per-keystroke settings lookups for
    /// non-digit terminal keys.
    private func eventCouldMatchNumberedShortcutDigit(_ event: NSEvent) -> Bool {
        shortcutCoordinator.eventCouldMatchNumberedDigit(
            eventKeyCode: event.keyCode,
            eventCharactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // The unconditional menu-validation policy lives in AppMenuCoordinator;
        // this witness only projects the live item's action selector across the
        // seam and forwards the decision.
        appMenuCoordinator.isMenuItemValid(
            actionSelectorName: item.action.map { NSStringFromSelector($0) }
        )
    }

    private func configureUserNotifications() {
        notificationDelivery.configureUserNotifications(delegate: self)
    }

    private func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        // The recursive match decision lives in AppMenuCoordinator: snapshot the
        // live menu into a value tree, ask the coordinator which item paths match
        // the target selector, then perform the live mutation app-side over those
        // paths.
        let paths = appMenuCoordinator.menuItemPathsToDisable(
            in: menuItemValidationNodes(of: menu),
            matching: NSStringFromSelector(action)
        )
        for path in paths {
            guard let item = menuItem(at: path, in: menu) else { continue }
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            item.isEnabled = false
        }
    }

    private func menuItemValidationNodes(of menu: NSMenu) -> [MenuItemValidationNode] {
        menu.items.map { item in
            MenuItemValidationNode(
                actionSelectorName: item.action.map { NSStringFromSelector($0) },
                submenu: item.submenu.map { menuItemValidationNodes(of: $0) }
            )
        }
    }

    private func menuItem(at path: IndexPath, in menu: NSMenu) -> NSMenuItem? {
        var currentMenu: NSMenu? = menu
        var resolved: NSMenuItem?
        for index in path {
            guard let items = currentMenu?.items, index < items.count else { return nil }
            resolved = items[index]
            currentMenu = resolved?.submenu
        }
        return resolved
    }

    private func ensureApplicationIcon() {
        appIconApplier.applyResolvedMode()
    }

    /// Builds the composition-root ``AppLaunchBootstrap`` for this app bundle.
    /// The launch-services-registration / single-instance / duplicate-launch
    /// logic moved into `CmuxWindowing`; this is the single app-side
    /// construction site, injecting the live bundle/process state plus the
    /// app-target startup breadcrumb sink and current-app activation.
    private func makeAppLaunchBootstrap(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> AppLaunchBootstrap {
        AppLaunchBootstrap(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleURL: bundleURL,
            currentPid: ProcessInfo.processInfo.processIdentifier,
            runningApplications: { bundleId in
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            },
            activateCurrent: {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
            },
            startupBreadcrumb: { event, fields in
                StartupBreadcrumbLog.append(event, fields: fields)
            }
        )
    }

    private func scheduleLaunchServicesBundleRegistration(
        bundleURL: URL = Bundle.main.bundleURL.standardizedFileURL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void = AppDelegate.enqueueLaunchServicesRegistrationWork,
        register: @escaping @Sendable (CFURL) -> OSStatus = { url in
            LSRegisterURL(url, true)
        },
        breadcrumb: @escaping @Sendable (_ message: String, _ data: [String: Any]) -> Void = { message, data in
            sentryBreadcrumb(message, category: "startup", data: data)
        }
    ) {
        makeAppLaunchBootstrap(bundleURL: bundleURL).scheduleLaunchServicesRegistration(
            scheduler: scheduler,
            register: register,
            breadcrumb: breadcrumb
        )
    }

#if DEBUG
    func scheduleLaunchServicesBundleRegistrationForTesting(
        bundleURL: URL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void,
        register: @escaping @Sendable (CFURL) -> OSStatus,
        breadcrumb: @escaping @Sendable (_ message: String, _ data: [String: Any]) -> Void = { _, _ in }
    ) {
        scheduleLaunchServicesBundleRegistration(
            bundleURL: bundleURL,
            scheduler: scheduler,
            register: register,
            breadcrumb: breadcrumb
        )
    }
#endif

    private func enforceSingleInstance() {
        makeAppLaunchBootstrap().enforceSingleInstance()
    }

    private func observeDuplicateLaunches() {
        workspaceObserver = makeAppLaunchBootstrap().observeDuplicateLaunches()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.notificationDelivery.handleNotificationResponse(response)
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor [weak self] in
            let options = self?.notificationDelivery.presentationOptions(for: notification) ?? []
            completionHandler(options)
        }
    }

    private func installMainWindowKeyObserver() {
        guard windowKeyObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowKeyObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleCmuxWindowBecameKey(note)
            }
        })
        windowKeyObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleCmuxWindowResignedKey(note)
            }
        })
    }

    private func installBrowserAddressBarFocusObservers() {
        guard browserAddressBarFocusObserver == nil,
              browserAddressBarBlurObserver == nil,
              browserWebViewFirstResponderObserver == nil else { return }

        browserAddressBarFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserDidFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let panelId = notification.object as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }; self.browserPanel(for: panelId)?.beginSuppressWebViewFocusForAddressBar()
                self.browserOmnibarFocusTracker.setFocused(panelId: panelId)
#if DEBUG
                cmuxDebugLog("addressBar FOCUS panelId=\(panelId.uuidString.prefix(8))")
#endif
            }
        }

        browserAddressBarBlurObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let panelId = notification.object as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }; self.browserPanel(for: panelId)?.endSuppressWebViewFocusForAddressBar()
                if self.browserOmnibarFocusTracker.clearFocus(ifTrackedPanelId: panelId) {
#if DEBUG
                    cmuxDebugLog("addressBar BLUR panelId=\(panelId.uuidString.prefix(8))")
#endif
                }
            }
        }

        browserWebViewFirstResponderObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleBrowserWebViewFirstResponderNotification(notification)
            }
        }
    }

    @MainActor
    private func handleBrowserWebViewFirstResponderNotification(_ notification: Notification) {
        guard let webView = notification.object as? CmuxWebView,
              let panel = browserPanelOwning(webView) else { return }
        let pointerInitiated = BrowserFirstResponderEvent(userInfo: notification.userInfo).pointerInitiated

        if let trackedPanelId = browserOmnibarFocusTracker.focusedPanelId,
           trackedPanelId != panel.id,
           let trackedPanel = browserPanel(for: trackedPanelId),
           !shouldPreserveBrowserAddressBarTracking(
               for: trackedPanel,
               trackedPanelMatchesWebView: false,
               pointerInitiatedWebFocus: pointerInitiated,
               in: trackedPanel.webView.window
           ) {
            trackedPanel.endSuppressWebViewFocusForAddressBar()
            browserOmnibarFocusTracker.clearFocus()
#if DEBUG
            cmuxDebugLog(
                "addressBar CLEAR panelId=\(trackedPanelId.uuidString.prefix(8)) " +
                "reason=stale_other_panel_webViewFirstResponder"
            )
#endif
        }

        guard !shouldPreserveBrowserAddressBarTracking(
            for: panel,
            trackedPanelMatchesWebView: panel.webView === webView,
            pointerInitiatedWebFocus: pointerInitiated,
            in: webView.window
        ) else {
#if DEBUG
            cmuxDebugLog(
                "addressBar CLEAR panelId=\(panel.id.uuidString.prefix(8)) " +
                "reason=skip_preserve_omnibar_handoff pointer=\(pointerInitiated ? 1 : 0)"
            )
#endif
            return
        }
        panel.endSuppressWebViewFocusForAddressBar()
        if browserOmnibarFocusTracker.clearFocus(ifTrackedPanelId: panel.id) {
#if DEBUG
            cmuxDebugLog(
                "addressBar CLEAR panelId=\(panel.id.uuidString.prefix(8)) " +
                "reason=webViewFirstResponder"
            )
#endif
        }
    }

    private func browserPanel(for panelId: UUID) -> BrowserPanel? {
        return workspaceContainingPanel(panelId: panelId)?.workspace.browserPanel(for: panelId)
    }

    func browserFindBarIsVisible(for webView: CmuxWebView) -> Bool {
        browserPanelOwning(webView)?.searchState != nil
    }

    func isBrowserFocusModeActive(for webView: CmuxWebView) -> Bool {
        browserPanelOwning(webView)?.isBrowserFocusModeActive == true
    }

    func isWebViewFocused(_ panel: BrowserPanel) -> Bool {
        guard let window = panel.webView.window else { return false }
        guard let fr = window.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: panel.webView)
    }

    private func browserFocusModePanelForShortcutEvent(_ event: NSEvent) -> BrowserPanel? {
        // Resolve the panel from the web view that owns the responder chain (the
        // same resolver every other browser shortcut uses), not the selected pane:
        // context-menu / web-view-focus entrypoints can focus a WKWebView without
        // updating focusedPanelId. Then confirm that web view actually holds focus,
        // so the bypass stops once focus moves to the sidebar/terminal (where the
        // page can't run the double-Escape exit anyway and cmux shortcuts must work).
        guard let panel = shortcutEventBrowserPanel(event),
              panel.isBrowserFocusModeActive,
              isWebViewFocused(panel) else {
            return nil
        }
        return panel
    }

    func handleBrowserFocusModeKeyEvent(
        _ event: NSEvent,
        webView: CmuxWebView,
        source: String
    ) -> BrowserFocusModeKeyDecision {
        browserPanelOwning(webView)?.handleBrowserFocusModeKeyEvent(event, reason: source) ?? .inactive
    }

    func browserFocusModeContextMenuState(for webView: CmuxWebView) -> (isActive: Bool, canToggle: Bool) {
        guard let panel = browserPanelOwning(webView) else {
            return (isActive: false, canToggle: false)
        }
        return (isActive: panel.isBrowserFocusModeActive, canToggle: panel.canToggleBrowserFocusMode)
    }

    @discardableResult
    func toggleBrowserFocusModeFromContextMenu(for webView: CmuxWebView) -> Bool {
        guard let panel = browserPanelOwning(webView) else { return false }
        return panel.toggleBrowserFocusMode(reason: "contextMenu", focusWebView: true)
    }

    private func shouldLetFocusedBrowserOwnFindShortcut(_ event: NSEvent) -> Bool {
        let shortcutWindow = resolvedShortcutEventWindow(event) ?? shortcutRoutingActiveWindow
        let shortcutResponder = shortcutWindow?.firstResponder
        let owningWebView = tabManager?.focusedBrowserPanel?.webView as? CmuxWebView
        guard let owningWebView else { return false }
        return shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
            event,
            responder: shortcutResponder,
            owningWebView: owningWebView
        )
    }

    private func browserPanelOwning(_ webView: CmuxWebView) -> BrowserPanel? {
        var candidateManagers: [TabManager] = []
        var seenManagers = Set<ObjectIdentifier>()

        func appendCandidate(_ manager: TabManager?) {
            guard let manager else { return }
            let identifier = ObjectIdentifier(manager)
            guard seenManagers.insert(identifier).inserted else { return }
            candidateManagers.append(manager)
        }

        if let window = webView.window,
           let context = contextForMainWindow(window) {
            appendCandidate(context.tabManager)
        }
        appendCandidate(tabManager)
        for context in registeredMainWindows {
            appendCandidate(context.tabManager)
        }

        for manager in candidateManagers {
            if let panel = browserPanelOwning(webView, in: manager) {
                return panel
            }
        }
        return nil
    }

    private func browserPanelOwning(_ webView: CmuxWebView, in manager: TabManager) -> BrowserPanel? {
        for workspace in manager.tabs {
            if let panel = workspace.panels.values
                .compactMap({ $0 as? BrowserPanel })
                .first(where: { $0.webView === webView }) {
                return panel
            }
        }
        return nil
    }

    /// Repoints the app's active-window pointers at `context` (or clears them
    /// when `nil`). The ``WindowLifecycleHosting`` witness stays on AppDelegate;
    /// active mirror storage lives on ``MainWindowRouter``.
    func repointActiveMainWindow(to context: RegisteredMainWindow?) {
        environment.mainWindowRouter.repointActiveWindow(to: context)
    }

    /// Activates `context` for a key `window`. The ``WindowLifecycleHosting``
    /// witness stays on AppDelegate while the router preserves the legacy debug
    /// logging order around the active-pointer repoint.
    func setActiveMainWindowContext(_ context: RegisteredMainWindow, keyWindow window: NSWindow) {
        environment.mainWindowRouter.setActiveWindowContext(context, keyWindow: window)
    }

    /// Makes `window` the active main window. Forwards to ``windowLifecycle``,
    /// which resolves the context and drives the app-side activate witness above.
    func setActiveMainWindow(_ window: NSWindow) {
        windowLifecycle.setActiveMainWindow(window)
    }

    /// The should-close gate for a main terminal window. Forwards to
    /// ``windowLifecycle``; the terminating flag and quit warning stay app-side
    /// witnesses.
    private func handleMainTerminalWindowShouldClose() -> Bool {
        windowLifecycle.handleMainTerminalWindowShouldClose()
    }

    /// Routes the quit-shortcut warning when a should-close is blocked on the
    /// last remaining main window. The ``WindowLifecycleHosting`` witness for the
    /// app-side warning presentation.
    func handleMainTerminalWindowQuitWarning() {
        // XCTest has no UI for the warn-before-quit dialog and would either block
        // on runModal or have NSApp.terminate kill the test process; the
        // coordinator's `handleMainTerminalWindowShouldClose` already returns
        // early under XCTest, so this only runs in a real session.
        _ = handleQuitShortcutWarning()
    }

    /// Persists `window`'s geometry as a placement fallback for the next window,
    /// skipped while terminating. The ``WindowLifecycleHosting`` teardown witness.
    func persistWindowGeometryOnClose(from window: NSWindow) {
        // Keep geometry available as a fallback for the next window placement.
        if !isTerminatingApp {
            captureWindowConfigFrame(window, reason: "windowClose")
            persistWindowGeometry(from: window)
        }
    }

    /// Notifies the main-window visibility controller that `window` has closed.
    /// The ``WindowLifecycleHosting`` teardown witness.
    func discardClosedWindow(_ window: NSWindow) {
        mainWindowVisibilityController.discardClosedWindow(window)
    }

    /// Publishes the `window.closed` cmux lifecycle event for `windowId` with the
    /// `appkit_close` origin. The ``WindowLifecycleHosting`` teardown witness.
    func publishMainWindowClosed(windowId: UUID) {
        windowConfigFrames.removeValue(forKey: windowId)
        publishCmuxWindowLifecycle(name: "window.closed", windowId: windowId, origin: "appkit_close")
    }

    /// Focuses `window` for an explicit focus request via the visibility
    /// controller, returning whether it took. The ``WindowLifecycleHosting``
    /// focus witness; the coordinator owns the publish decision.
    func focusMainWindowForFocusRequest(_ window: NSWindow) -> Bool {
        mainWindowVisibilityController.focus(window, reason: .focusMainWindow)
    }

    /// Publishes the `window.focused` cmux lifecycle event for `windowId` with the
    /// `focus_request` origin. The ``WindowLifecycleHosting`` focus witness.
    func publishMainWindowFocused(windowId: UUID) {
        publishCmuxWindowLifecycle(name: "window.focused", windowId: windowId, origin: "focus_request")
    }

    /// Sends `window` the standard AppKit close (routes through the should-close
    /// gate). The ``WindowLifecycleHosting`` close witness.
    func performMainWindowClose(_ window: NSWindow) {
        window.performClose(nil)
    }

    /// Closes `window` immediately, bypassing the should-close gate, for the
    /// discard-without-history path. The ``WindowLifecycleHosting`` close witness.
    func closeMainWindowImmediately(_ window: NSWindow) {
        window.close()
    }

    /// Removes `windowId` from the command-palette presentation coordinator. The
    /// ``WindowLifecycleHosting`` teardown counterpart of `commandPaletteRegisterWindow`.
    func commandPaletteRemoveWindow(_ windowId: UUID) {
        commandPalettePresentation.removeWindow(windowId)
    }

    /// Clears every notification owned by `context`'s window id and tabs once
    /// the window is gone. The ``WindowLifecycleHosting`` teardown witness.
    func clearNotifications(forClosing context: RegisteredMainWindow) {
        // Avoid stale notifications that can no longer be opened once the owning window is gone.
        guard let store = notificationStore else { return }
        store.clearNotifications(forTabId: context.windowId)
        for tab in context.tabManager.tabs {
            store.clearNotifications(forTabId: tab.id)
        }
    }

    /// Whether `context`'s tab manager is the current active tab manager. The
    /// ``WindowLifecycleHosting`` witness gating the teardown active-window repoint.
    func activeTabManagerMatches(_ context: RegisteredMainWindow) -> Bool {
        tabManager === context.tabManager
    }

    /// Saves a post-unregister session snapshot (no scrollback) when the
    /// persistence policy allows it. The ``WindowLifecycleHosting`` teardown
    /// witness.
    func saveSessionSnapshotOnWindowUnregisterIfNeeded(
        removeWhenEmpty: Bool,
        preserveManualRestoreBackupOnMissingPrimary: Bool
    ) {
        // During app termination we already persisted a full snapshot (with scrollback)
        // in applicationShouldTerminate/applicationWillTerminate. Saving again here would
        // overwrite it as windows tear down one-by-one, dropping closed windows and replay.
        if Self.sessionPersistenceDecisionPolicy.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: isTerminatingApp) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(
                includeScrollback: false,
                removeWhenEmpty: removeWhenEmpty,
                preserveManualRestoreBackupOnMissingPrimary: preserveManualRestoreBackupOnMissingPrimary
            )
        }
    }

    func closingWindowIsCrashDiagnostic(_ context: RegisteredMainWindow) -> Bool {
        closeWindowSnapshotPruningCrashDiagnostics(
            for: context,
            includeScrollback: false,
            restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh() ?? .empty
        )
            .isCrashDiagnostic
    }

    private func closeWindowSnapshotPruningCrashDiagnostics(
        for context: RegisteredMainWindow,
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex
    ) -> (snapshot: SessionWindowSnapshot?, isCrashDiagnostic: Bool) {
        let windowSnapshot = sessionWindowSnapshot(
            for: context,
            includeScrollback: includeScrollback,
            restorableAgentIndex: restorableAgentIndex
        )
        let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(
            from: AppSessionSnapshot(
                version: AppSessionSnapshot.currentSchemaVersion,
                createdAt: Date().timeIntervalSince1970,
                windows: [windowSnapshot]
            )
        )
        return (
            pruned.snapshot?.windows.first,
            pruned.removedAny && pruned.snapshot == nil
        )
    }

    func recordClosedWindowHistoryIfNeeded(for context: RegisteredMainWindow) {
        let shouldSuppressClosedWindowHistory = closedWindowHistorySuppressedWindowIds.remove(context.windowId) != nil
        guard !shouldSuppressClosedWindowHistory,
              !isTerminatingApp,
              !isApplyingSessionRestore else {
            return
        }
        // Closing the last tab closes the window, recording undo history. Prefer the warm
        // cached agent index over a synchronous `RestorableAgentSessionIndex.load()` so the
        // close does not freeze the main thread; fall back to a fresh load only while the
        // cache has not loaded yet (see closedPanelHistoryEntry).
        let restorableAgentIndex = SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
            ?? RestorableAgentSessionIndex.load()
        guard let snapshot = closeWindowSnapshotPruningCrashDiagnostics(
            for: context,
            includeScrollback: true,
            restorableAgentIndex: restorableAgentIndex
        ).snapshot else {
            return
        }
        guard !snapshot.tabManager.workspaces.isEmpty else {
            return
        }
        closedItemHistory.push(.window(ClosedWindowHistoryEntry(
            windowId: context.windowId,
            snapshot: snapshot,
            workspaceIds: snapshot.tabManager.workspaces.compactMap(\.workspaceId)
        )))
    }

#if DEBUG
    func suppressClosedWindowHistoryForTesting(windowId: UUID) {
        closedWindowHistorySuppressedWindowIds.insert(windowId)
    }

    func recordClosedWindowHistoryForTesting(windowId: UUID) {
        guard let context = registeredMainWindow(forWindowId: windowId) else { return }
        recordClosedWindowHistoryIfNeeded(for: context)
    }

    func isClosedWindowHistorySuppressedForTesting(windowId: UUID) -> Bool {
        closedWindowHistorySuppressedWindowIds.contains(windowId)
    }
#endif

    func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        if windowCoordinator.id(for: window) != nil {
            return true
        }
        guard let raw = window.identifier?.rawValue else { return false }
        return MainTerminalWindowIdentifier.matches(rawIdentifier: raw)
    }

    /// Returns the `Workspace` that owns `tabId`, if any.
    @MainActor
    func workspaceFor(tabId: UUID) -> Workspace? {
        windowRegistry.workspaceFor(tabId: tabId)
    }

    func closeMainWindowContainingTabId(_ tabId: UUID, recordHistory: Bool = true) {
#if DEBUG
        closeMainWindowContainingTabIdObserverForTesting?(tabId, recordHistory)
#endif
        guard let context = windowRegistry.contextContainingTabId(tabId) else { return }
        let expectedIdentifier = MainTerminalWindowIdentifier(forWindowId: context.windowId).expectedIdentifier
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        if !recordHistory {
            closedWindowHistorySuppressedWindowIds.insert(context.windowId)
        }
        guard let window else {
            if !recordHistory {
                closedWindowHistorySuppressedWindowIds.remove(context.windowId)
            }
            return
        }
        window.performClose(nil)
    }

    @discardableResult
    @MainActor
    func openTerminalNotification(_ notification: TerminalNotification) -> Bool {
        notificationNavigation.openNotification(notification.navSnapshot)
    }

    /// Performs a notification click action. Forwards to the shared
    /// `NotificationClickPerformer` (which owns the tilde-expansion and
    /// file-vs-directory reveal logic); `AppDelegate` only supplies the
    /// `NSWorkspace`/`FileManager` side effect through `FinderRevealing`. Both
    /// the navigation coordinator and the `UNUserNotificationCenter` delegate
    /// path reach reveal-in-Finder through this one performer.
    @discardableResult
    @MainActor
    func performTerminalNotificationClickAction(_ action: TerminalNotificationClickAction) -> Bool {
        notificationClickPerformer.perform(action.navClickAction)
    }

    // MARK: NotificationOpenRoutingHosting witnesses
    //
    // The window mechanics behind ``NotificationOpenRoutingHosting``, lifted off
    // the old `openNotification*` bodies and kept on `AppDelegate` so they retain
    // access to the late-bound window/tab/store state. The
    // ``NotificationOpenRoutingSeamAdapter`` forwards each seam method here.
    // Behavior is byte-identical to the previous inlined branches.

    /// Resolves the registered window context that owns `tabId`, boxed for the
    /// open-routing seam. Mirrors the window-registry lookup, resolving once.
    func openRoutingContextToken(forTabId tabId: UUID) -> AnyObject? {
        guard let context = windowRegistry.contextContainingTabId(tabId) else { return nil }
        return RegisteredMainWindowToken(context)
    }

    /// The live `NSWindow` for `contextToken`'s window, or `nil` when not realized.
    /// Mirrors `context.window ?? NSApp.windows.first(where: identifier == expected)`.
    func openRoutingContextWindowToken(forContextToken contextToken: AnyObject) -> AnyObject? {
        guard let context = (contextToken as? RegisteredMainWindowToken)?.context else { return nil }
        let expectedIdentifier = MainTerminalWindowIdentifier(forWindowId: context.windowId).expectedIdentifier
        return context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    /// Selects the tabs pane on `contextToken`'s per-window sidebar selection.
    func openRoutingSelectSidebarTabs(forContextToken contextToken: AnyObject) {
        guard let context = (contextToken as? RegisteredMainWindowToken)?.context else { return }
        sidebarSelectionState(for: context).selection = .tabs
    }

    /// Focuses `tabId`/`surfaceId` in `contextToken`'s tab manager.
    func openRoutingFocusTab(forContextToken contextToken: AnyObject, tabId: UUID, surfaceId: UUID?) -> Bool {
        guard let context = (contextToken as? RegisteredMainWindowToken)?.context else { return false }
        return context.tabManager.focusTabFromNotification(tabId, surfaceId: surfaceId)
    }

    /// Whether an active (global) tab manager exists for the fallback route.
    var openRoutingHasActiveTabManager: Bool {
        tabManager != nil
    }

    /// Whether the active tab manager owns `tabId`.
    func openRoutingActiveTabManagerContains(tabId: UUID) -> Bool {
        tabManager?.tabs.contains(where: { $0.id == tabId }) ?? false
    }

    /// The key window or first main terminal window for the fallback route.
    func openRoutingKeyOrMainTerminalWindowToken() -> AnyObject? {
        NSApp.keyWindow ?? NSApp.windows.first(where: { isMainTerminalWindow($0) })
    }

    /// Selects the tabs pane on the active (global) sidebar selection.
    func openRoutingSelectActiveSidebarTabs() {
        sidebarSelectionState?.selection = .tabs
    }

    /// Focuses `tabId`/`surfaceId` in the active tab manager.
    func openRoutingFocusTabInActiveTabManager(tabId: UUID, surfaceId: UUID?) -> Bool {
        tabManager?.focusTabFromNotification(tabId, surfaceId: surfaceId) ?? false
    }

    /// Brings `windowToken` to front. Mirrors `bringToFront(window)`.
    func openRoutingBringWindowToFront(_ windowToken: AnyObject) {
        guard let window = windowToken as? NSWindow else { return }
        bringToFront(window)
    }

    /// Marks `notificationId` read when both it and the store are present.
    func openRoutingMarkNotificationRead(notificationId: UUID?) {
        if let notificationId, let store = notificationStore {
            store.markRead(id: notificationId)
        }
    }

    // MARK: NotificationOpenRoutingTracing witnesses
    //
    // The `#if DEBUG` UI-test recorders behind ``NotificationOpenRoutingTracing``.
    // Each reproduces one legacy recorder call site verbatim and is an empty
    // no-op in production. ``NotificationOpenRoutingSeamAdapter`` forwards here.

    func openRoutingTraceOpenCalled(tabId: UUID, surfaceId: UUID?) {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.openCalled(tabId: tabId, surfaceId: surfaceId).fields)
        }
#endif
    }

    func openRoutingRecordOpenFailureMissingContext(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) {
#if DEBUG
        recordMultiWindowNotificationOpenFailureIfNeeded(
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId,
            reason: NotificationOpenRoutingTrace.missingContextReason
        )
#endif
    }

    func openRoutingTraceContextMissingUsedFallback() {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.contextMissingUsedFallback.fields)
        }
#endif
    }

    func openRoutingTraceOpenResult(_ ok: Bool) {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.openResult(ok).fields)
        }
#endif
    }

    func openRoutingTraceContextFoundNoFallback() {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.contextFoundNoFallback.fields)
        }
#endif
    }

    func openRoutingRecordOpenFailureMissingWindow(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?
    ) {
#if DEBUG
        guard let context = (contextToken as? RegisteredMainWindowToken)?.context else { return }
        let expectedIdentifier = MainTerminalWindowIdentifier(forWindowId: context.windowId).expectedIdentifier
        recordMultiWindowNotificationOpenFailureIfNeeded(
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId,
            reason: NotificationOpenRoutingTrace.missingWindowReason(expectedIdentifier: expectedIdentifier)
        )
#endif
    }

    func openRoutingTraceInContextFocusFailed(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?
    ) {
#if DEBUG
        recordMultiWindowNotificationOpenFailureIfNeeded(
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId,
            reason: NotificationOpenRoutingTrace.focusFailedReason
        )
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.openResult(false).fields)
        }
#endif
    }

    func openRoutingRecordJumpUnreadFocusFromModelInContext(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?
    ) {
#if DEBUG
        guard let context = (contextToken as? RegisteredMainWindowToken)?.context else { return }
        // UI test support: Jump-to-unread asserts that the correct workspace/panel is focused.
        // Recording via first-responder can be flaky on the VM, so verify focus via the model.
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: context.tabManager,
            tabId: tabId,
            expectedSurfaceId: surfaceId
        )
#endif
    }

    func openRoutingTraceInContextOpened(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?
    ) {
#if DEBUG
        guard let context = (contextToken as? RegisteredMainWindowToken)?.context else { return }
        recordMultiWindowNotificationFocusIfNeeded(
            windowId: context.windowId,
            tabId: tabId,
            surfaceId: surfaceId,
            sidebarSelection: sidebarSelectionState(for: context).selection
        )
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.openedInContext.fields)
        }
#endif
    }

    func openRoutingTraceFallbackFailed(stage: String) {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.fallbackFailed(stage).fields)
        }
#endif
    }

    func openRoutingRecordJumpUnreadFocusFromModelActive(tabId: UUID, surfaceId: UUID?) {
#if DEBUG
        guard let tabManager else { return }
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: tabManager,
            tabId: tabId,
            expectedSurfaceId: surfaceId
        )
#endif
    }

    func openRoutingTraceFallbackFocusFailed() {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.fallbackFocusFailed.fields)
        }
#endif
    }

    func openRoutingTraceOpenedInFallback() {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(NotificationOpenRoutingTrace.openedInFallback.fields)
        }
#endif
    }

#if DEBUG
    /// Live selection-model hook: records the jump-to-unread focus once the
    /// model settles on the expected tab/surface. Forwards to
    /// ``JumpUnreadUITestRecorder``.
    func recordJumpUnreadFocusFromModelIfNeeded(
        tabManager: TabManager,
        tabId: UUID,
        expectedSurfaceId: UUID?
    ) {
        let recorder = jumpUnreadUITestRecorder ?? JumpUnreadUITestRecorder(appDelegate: self)
        jumpUnreadUITestRecorder = recorder
        recorder.recordFocusFromModelIfNeeded(
            tabManager: tabManager,
            tabId: tabId,
            expectedSurfaceId: expectedSurfaceId
        )
    }
#endif

    func tabTitle(for tabId: UUID) -> String? {
        if let context = windowRegistry.contextContainingTabId(tabId) {
            return context.tabManager.tabs.first(where: { $0.id == tabId })?.title
        }
        return tabManager?.tabs.first(where: { $0.id == tabId })?.title
    }

    func bringToFront(
        _ window: NSWindow,
        reason: MainWindowVisibilityController.Reason = .focusMainWindow
    ) {
        _ = mainWindowVisibilityController.focus(window, reason: reason)
    }

#if DEBUG
    /// Forwards the multi-window notification open-failure record to the
    /// ``MultiWindowNotificationUITestScaffold`` (which snapshots the live
    /// `mainWindowContexts` and writes the env-gated capture file), creating it
    /// lazily if an open-failure fires before setup ran.
    func recordMultiWindowNotificationOpenFailureIfNeeded(
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?,
        reason: String
    ) {
        let scaffold = multiWindowNotificationUITestScaffold
            ?? MultiWindowNotificationUITestScaffold(appDelegate: self)
        multiWindowNotificationUITestScaffold = scaffold
        scaffold.recordOpenFailureIfNeeded(
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId,
            reason: reason
        )
    }
#endif

}

#if DEBUG
private var cmuxFirstResponderGuardCurrentEventOverride: NSEvent?
private var cmuxFirstResponderGuardHitViewOverride: NSView?
#endif
private var cmuxFirstResponderGuardCurrentEventContext: NSEvent?
private var cmuxFirstResponderGuardHitViewContext: NSView?
private var cmuxFirstResponderGuardContextWindowNumber: Int?

private extension NSApplication {
    @objc func cmux_accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        if Thread.isMainThread, let cache = AppDelegate.shared?.accessibilityWindowCache {
            switch cache.resolve(
                attribute: attribute,
                application: self
            ) {
            case .handled(let value):
                return value
            case .passthrough:
                break
            }
        }

        return cmux_accessibilityAttributeValue(attribute)
    }

    @objc func cmux_applicationSendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        if event.type == .keyDown {
            CmuxTypingTiming.logEventDelay(path: "app.sendEvent", event: event)
        }
        defer {
            if event.type == .keyDown {
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "app.sendEvent.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 1.0,
                    parts: [("dispatchMs", totalMs)]
                )
                CmuxTypingTiming.logDuration(
                    path: "app.sendEvent",
                    startedAt: typingTimingStart,
                    event: event
                )
            }
        }
#endif
        if event.type == .leftMouseDown,
           AppDelegate.shared?.handleMinimalModeTitlebarDoubleClickMouseDown(event: event) == true {
            return
        }
        if ShortcutRecorderEventRouter.dispatchActiveRecordingEvent(
            event,
            preferredWindow: event.window ?? AppDelegate.shared?.shortcutRoutingActiveWindow ?? keyWindow ?? mainWindow
        ) {
            return
        }
        if AppDelegate.shared?.shouldSuppressStaleCmuxMenuShortcut(event: event) == true {
            if AppDelegate.shared?.handleConfiguredShortcutKeyEquivalent(event) == true {
#if DEBUG
                cmuxDebugLog("app.sendEvent routed configured shortcut before stale cmux menu shortcut")
#endif
                return
            }
            let responder = event.window?.firstResponder
                ?? AppDelegate.shared?.shortcutRoutingKeyWindow?.firstResponder
                ?? mainWindow?.firstResponder
            if let ghosttyView = cmuxOwningGhosttyView(for: responder) {
                ghosttyView.keyDown(with: event)
#if DEBUG
                cmuxDebugLog("app.sendEvent suppressed stale cmux menu shortcut and forwarded to terminal")
#endif
            } else {
#if DEBUG
                cmuxDebugLog("app.sendEvent suppressed stale cmux menu shortcut")
#endif
            }
            return
        }
        cmux_applicationSendEvent(event)
    }

    @objc func cmux_sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        if AppDelegate.shared?.handleDetachedInspectorWindowCloseAction(
            action: action,
            target: target,
            sender: sender
        ) == true {
            return true
        }

        return cmux_sendAction(action, to: target, from: sender)
    }
}

private extension AppDelegate {
    @discardableResult
    func handleMinimalModeTitlebarDoubleClickMouseDown(event: NSEvent) -> Bool {
        windowDecorationsController.handleMinimalModeTitlebarDoubleClickMouseDown(event: event)
    }

    @discardableResult
    func handleMinimalModeSidebarChromeMouseDown(window: NSWindow, event: NSEvent) -> Bool {
        windowDecorationsController.handleMinimalModeSidebarChromeMouseDown(window: window, event: event)
    }

    @objc func handleThemesReloadNotification(_ notification: Notification) {
        let targetBundleIdentifier =
            notification.userInfo?["bundleIdentifier"] as? String
            ?? notification.object as? String
        if let targetBundleIdentifier,
           let bundleIdentifier = Bundle.main.bundleIdentifier,
           !targetBundleIdentifier.isEmpty,
           targetBundleIdentifier != bundleIdentifier {
            return
        }

        let source = GhosttySurfaceConfigurationRefresh.cmuxThemeReloadSource(
            phase: notification.userInfo?["phase"] as? String
        )
        DispatchQueue.main.async {
            self.reloadGhosttyConfigurationForCmuxThemeSource(source)
        }
    }

    func reloadGhosttyConfigurationForCmuxThemeSource(_ source: String) {
        if GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload(source: source) {
            cmuxThemePreviewReloadGeneration += 1
            let generation = cmuxThemePreviewReloadGeneration
            cmuxThemePreviewReloadWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.cmuxThemePreviewReloadGeneration == generation else { return }
                self.cmuxThemePreviewReloadWorkItem = nil
                self.reloadConfiguration(source: source)
            }
            cmuxThemePreviewReloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(
                    GhosttySurfaceConfigurationRefresh.cmuxThemePreviewReloadDebounceMilliseconds
                ),
                execute: workItem
            )
            return
        }

        cmuxThemePreviewReloadGeneration += 1
        cmuxThemePreviewReloadWorkItem?.cancel()
        cmuxThemePreviewReloadWorkItem = nil
        reloadConfiguration(source: source)
    }
}

extension AppDelegate {
    func browserPanelsForInspectorFocusHandoff() -> [BrowserPanel] {
        allBrowserPanelsForInspectorWindowClose()
    }
}

private extension NSWindow {
    static func cmuxCommandPaletteOwnsFieldEditor(_ textView: NSTextView?, in window: NSWindow) -> Bool {
        guard let textView,
              textView.isFieldEditor,
              textView.window === window else {
            return false
        }

        if let ownerView = cmuxFieldEditorOwnerView(textView) {
            guard let container = ownerView.commandPaletteOverlayAncestor else {
                return false
            }
            return container.isCommandPaletteOverlayContainerPresented
        }

        guard let container = window.commandPaletteOverlayContainerView else {
            return false
        }

        return container.isCommandPaletteOverlayContainerPresented
    }

    @objc func cmux_makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if AppDelegate.shared?.browserFirstResponderBypass.isActive == true {
#if DEBUG
            cmuxDebugLog(
                "focus.guard bypassFirstResponder responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        let currentEvent = Self.cmuxCurrentEvent(for: self)
        let responderWebView = responder.flatMap {
            Self.cmuxOwningWebView(for: $0, in: self, event: currentEvent)
        }
        var pointerInitiatedWebFocus = false
        var pointerInitiatedTerminalFocus = false

        if AppDelegate.shared?.shouldBlockFirstResponderChangeWhileCommandPaletteVisible(
            window: self,
            responder: responder
        ) == true {
#if DEBUG
            cmuxDebugLog(
                "focus.guard commandPaletteBlocked responder=\(String(describing: responder.map { type(of: $0) })) " +
                "window=\(ObjectIdentifier(self))"
            )
#endif
            return false
        }

        if let request = AppDelegate.shared?.terminalKeyboardFocusRequest(for: responder),
           Self.cmuxShouldAllowPointerInitiatedTerminalFocus(
               window: self,
               request: request,
               event: currentEvent
           ) {
            pointerInitiatedTerminalFocus = true
            AppDelegate.shared?.noteTerminalKeyboardFocusIntent(
                workspaceId: request.workspaceId,
                panelId: request.panelId,
                in: self
            )
#if DEBUG
            cmuxDebugLog(
                "focus.guard allowPointerTerminalFirstResponder " +
                "window=\(ObjectIdentifier(self)) " +
                "workspace=\(request.workspaceId.uuidString.prefix(5)) " +
                "panel=\(request.panelId.uuidString.prefix(5)) " +
                "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
            )
#endif
        }

        if let responder,
           AppDelegate.shared?.allowsTerminalKeyboardFocus(for: responder, in: self) == false {
#if DEBUG
            if let request = AppDelegate.shared?.terminalKeyboardFocusRequest(for: responder) {
                dlog(
                    "focus.guard blockedTerminalFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "workspace=\(request.workspaceId.uuidString.prefix(5)) " +
                    "panel=\(request.panelId.uuidString.prefix(5))"
                )
            } else {
                dlog(
                    "focus.guard blockedTerminalFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self))"
                )
            }
#endif
            return false
        }

        if let responder,
           let webView = responderWebView,
           !webView.allowsFirstResponderAcquisitionEffective {
            let pointerInitiatedFocus = Self.cmuxShouldAllowPointerInitiatedWebViewFocus(
                window: self,
                webView: webView,
                event: currentEvent
            )
            if pointerInitiatedFocus {
                pointerInitiatedWebFocus = true
#if DEBUG
                cmuxDebugLog(
                    "focus.guard allowPointerFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
            } else {
#if DEBUG
                cmuxDebugLog(
                    "focus.guard blockedFirstResponder responder=\(String(describing: type(of: responder))) " +
                    "window=\(ObjectIdentifier(self)) " +
                    "web=\(ObjectIdentifier(webView)) " +
                    "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                    "pointerDepth=\(webView.debugPointerFocusAllowanceDepth) " +
                    "eventType=\(currentEvent.map { String(describing: $0.type) } ?? "nil")"
                )
#endif
                return false
            }
        }
#if DEBUG
        if let responder,
           let webView = responderWebView {
            cmuxDebugLog(
                "focus.guard allowFirstResponder responder=\(String(describing: type(of: responder))) " +
                "window=\(ObjectIdentifier(self)) " +
                "web=\(ObjectIdentifier(webView)) " +
                "policy=\(webView.allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(webView.debugPointerFocusAllowanceDepth)"
            )
        }
#endif
        let result: Bool
        if pointerInitiatedWebFocus, let webView = responderWebView {
            // `NSWindow.makeFirstResponder` may run before `CmuxWebView.mouseDown(with:)`.
            // Preserve pointer intent during this synchronous responder change.
            result = webView.withPointerFocusAllowance {
                cmux_makeFirstResponder(responder)
            }
        } else {
            result = cmux_makeFirstResponder(responder)
        }
        if result {
            AppDelegate.shared?.postBrowserInspectorClickIntentIfNeeded(for: responder, in: self, event: currentEvent)
            if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
                Self.cmuxTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            } else if let fieldEditor = self.firstResponder as? NSTextView, fieldEditor.isFieldEditor {
                Self.cmuxTrackFieldEditor(fieldEditor, owningWebView: responderWebView)
            }
            AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: self)
        } else if pointerInitiatedTerminalFocus {
            AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: self)
        }
        return result
    }

    @objc func cmux_sendEvent(_ event: NSEvent) {
#if DEBUG
        let typingTimingStart = event.type == .keyDown ? CmuxTypingTiming.start() : nil
        let phaseTotalStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
        var contextSetupMs: Double = 0
        var focusRepairMs: Double = 0
        var folderGuardMs: Double = 0
        var originalDispatchMs: Double = 0
        let typingTimingExtra: String? = {
            guard event.type == .keyDown else { return nil }
            let responderWebView = self.firstResponder.flatMap {
                Self.cmuxOwningWebView(for: $0, in: self, event: event)
            }
            let firstResponderType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return "browser=\(responderWebView != nil ? 1 : 0) firstResponder=\(firstResponderType)"
        }()
        if event.type == .keyDown {
            CmuxTypingTiming.logEventDelay(path: "window.sendEvent", event: event)
        }
#endif
        // recordTypingActivity must run in all builds so the session autosave
        // scheduler can honor the typing quiet period in release.
        if event.type == .keyDown, let app = AppDelegate.shared, cmuxCloseFocusedTerminalFindForEscape(event: event, appDelegate: app) { return }
        if event.type == .keyDown { AppDelegate.shared?.recordTypingActivity() }
        if event.type == .leftMouseDown,
           AppDelegate.shared?.handleMinimalModeSidebarChromeMouseDown(window: self, event: event) == true {
            return
        }
#if DEBUG
        defer {
            if event.type == .keyDown {
                let totalMs = (ProcessInfo.processInfo.systemUptime - phaseTotalStart) * 1000.0
                CmuxTypingTiming.logBreakdown(
                    path: "window.sendEvent.phase",
                    totalMs: totalMs,
                    event: event,
                    thresholdMs: 1.0,
                    parts: [
                        ("contextSetupMs", contextSetupMs),
                        ("focusRepairMs", focusRepairMs),
                        ("folderGuardMs", folderGuardMs),
                        ("originalDispatchMs", originalDispatchMs),
                    ],
                    extra: typingTimingExtra
                )
                CmuxTypingTiming.logDuration(
                    path: "window.sendEvent",
                    startedAt: typingTimingStart,
                    event: event,
                    extra: typingTimingExtra
                )
            }
        }
        let contextSetupStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        let previousContextEvent = cmuxFirstResponderGuardCurrentEventContext
        let previousContextHitView = cmuxFirstResponderGuardHitViewContext
        let previousContextWindowNumber = cmuxFirstResponderGuardContextWindowNumber
        cmuxFirstResponderGuardCurrentEventContext = event
        cmuxFirstResponderGuardHitViewContext = Self.cmuxHitViewForFirstResponderGuard(in: self, event: event)
        cmuxFirstResponderGuardContextWindowNumber = self.windowNumber
#if DEBUG
        if event.type == .keyDown {
            contextSetupMs = (ProcessInfo.processInfo.systemUptime - contextSetupStart) * 1000.0
        }
        let focusRepairStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        if event.type == .keyDown {
            AppDelegate.shared?.repairFocusedTerminalKeyboardRoutingIfNeeded(
                window: self,
                event: event
            )
        }
#if DEBUG
        if event.type == .keyDown {
            focusRepairMs = (ProcessInfo.processInfo.systemUptime - focusRepairStart) * 1000.0
        }
        let folderGuardStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        defer {
            cmuxFirstResponderGuardCurrentEventContext = previousContextEvent
            cmuxFirstResponderGuardHitViewContext = previousContextHitView
            cmuxFirstResponderGuardContextWindowNumber = previousContextWindowNumber
        }

        let suppressionReason = beginOrContinueWindowMoveSuppressionSequenceForEvent(window: self, event: event)
        let hasActiveSuppressionSequence = self.activeWindowMoveSuppressionSequenceReason != nil
        guard suppressionReason != nil || hasActiveSuppressionSequence else {
#if DEBUG
            if event.type == .keyDown {
                folderGuardMs = (ProcessInfo.processInfo.systemUptime - folderGuardStart) * 1000.0
                let originalDispatchStart = ProcessInfo.processInfo.systemUptime
                cmux_sendEvent(event)
                originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
                return
            }
#endif
            cmux_sendEvent(event)
            return
        }
#if DEBUG
        if event.type == .keyDown {
            folderGuardMs = (ProcessInfo.processInfo.systemUptime - folderGuardStart) * 1000.0
        }
        let originalDispatchStart = event.type == .keyDown ? ProcessInfo.processInfo.systemUptime : 0
#endif
        let shouldFinishSuppression = shouldFinishWindowMoveSuppressionSequenceAfterDispatch(window: self, event: event)

#if DEBUG
        let hitView = WindowInputRoutingContext(event: event).allowsPortalPointerHitTesting
            ? Self.cmuxHitViewForEventDispatch(in: self, event: event)
            : nil
#endif
        defer {
            let finishedReason: WindowMoveSuppressionReason?
            if shouldFinishSuppression {
                finishedReason = self.finishWindowMoveSuppressionSequence()
            } else {
                finishedReason = nil
            }
            #if DEBUG
            let reasonDescription = finishedReason?.rawValue ?? suppressionReason?.rawValue ?? "activeSequence"
            if shouldFinishSuppression {
                cmuxDebugLog("window.sendEvent.\(reasonDescription) finish nowMovable=\(isMovable)")
            } else {
                cmuxDebugLog("window.sendEvent.\(reasonDescription) keepSuppressed nowMovable=\(isMovable)")
            }
            #endif
        }

        #if DEBUG
        let hitDesc = hitView.map { String(describing: type(of: $0)) } ?? "nil"
        let depth = self.windowDragSuppressionDepth
        let reasonDescription = suppressionReason?.rawValue ?? "activeSequence"
        cmuxDebugLog("window.sendEvent.\(reasonDescription) suppress=1 hit=\(hitDesc) movable=\(isMovable) depth=\(depth)")
        #endif

        cmux_sendEvent(event)
#if DEBUG
        if event.type == .keyDown {
            originalDispatchMs = (ProcessInfo.processInfo.systemUptime - originalDispatchStart) * 1000.0
        }
#endif
    }

    @objc func cmux_performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "window.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event
            )
        }
        let frType = self.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        cmuxDebugLog("performKeyEquiv: \(event.cmuxKeyDescription) fr=\(frType)")
#endif

        // When a terminal owns first responder, bypass SwiftUI's hosting view:
        // after browser focus churn it can claim key equivalents without firing.
        // Non-Command keys go to Ghostty; Command keys go to the main menu.
        let firstResponderGhosttyView = cmuxOwningGhosttyView(for: self.firstResponder)
        let firstResponderWebView = self.firstResponder.flatMap {
            Self.cmuxOwningWebView(for: $0, in: self, event: event)
        }
        let firstResponderHasMarkedText = browserResponderHasMarkedText(self.firstResponder)
        let firstResponderIsCommandPaletteFieldEditor = Self.cmuxCommandPaletteOwnsFieldEditor(
            self.firstResponder as? NSTextView,
            in: self
        )
        let firstResponderOmnibarPanelId = BrowserOmnibarNativeFieldRegistry.shared.omnibarPanelId(for: self.firstResponder)
        let firstResponderIsTextBoxInput = self.firstResponder is TextBoxInputTextView
        // A standalone editable document text view (e.g. the file-preview
        // editor's SavingTextView) owns arrow navigation through its own
        // keyDown. Field editors (omnibar / command palette / find) are
        // excluded — they route through their dedicated paths above.
        let firstResponderIsStandaloneEditableTextView: Bool = {
            guard let textView = self.firstResponder as? NSTextView else { return false }
            return textView.isEditable && !textView.isFieldEditor
        }()
        if ShortcutRecorderEventRouter.dispatchActiveRecordingEvent(event, preferredWindow: self) {
            return true
        }
        let browserWebKitKeyDownReentry = firstResponderWebView != nil && cmuxBrowserWebKitKeyDownDispatchIsActive()
        if AppDelegate.shared?.shouldBypassPrintableOptionTextForShortcutRouting(event: event) == true {
            if browserWebKitKeyDownReentry { return false }
            let textInputTarget: NSResponder? = firstResponderGhosttyView
                ?? firstResponderWebView
                ?? self.firstResponder
            if let textInputTarget, textInputTarget !== self {
                if cmuxForceDispatchKeyDownOnce(event, to: textInputTarget, reason: "printable Option text") {
                    return true
                }
                // Same event already in flight on this stack (WebKit replay /
                // macOS 26 NSWindow.keyDown re-entry): decline so default
                // AppKit handling proceeds instead of looping.
                return false
            }
            return false
        }
        if cmuxRouteUndoRedoCommandEquivalentAwayFromAppKit(event, terminalView: firstResponderGhosttyView, webView: firstResponderWebView, browserWebKitKeyDownReentry: browserWebKitKeyDownReentry) { return true }
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event),
           AppDelegate.shared?.shouldRouteRightSidebarModeShortcut(in: self) == true {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: self
            )
            return true
        }
        if AppDelegate.shared?.shouldSuppressStaleCmuxMenuShortcut(event: event) == true {
            if AppDelegate.shared?.handleConfiguredShortcutKeyEquivalent(event) == true {
#if DEBUG
                cmuxDebugLog("  → consumed by configured shortcut before stale cmux menu shortcut")
#endif
                return true
            }
            if let firstResponderGhosttyView,
               cmuxForceDispatchKeyDownOnce(
                   event,
                   to: firstResponderGhosttyView,
                   reason: "stale cmux menu shortcut terminal bypass"
               ) {
#if DEBUG
                cmuxDebugLog("  → terminal received command equivalent bypassing stale cmux menu shortcut")
#endif
                return true
            }
#if DEBUG
            cmuxDebugLog("  → suppressed stale cmux menu shortcut")
#endif
            return false
        }
        if let ghosttyView = firstResponderGhosttyView {
            // If the IME is composing and the key has no Cmd modifier, don't intercept —
            // let it flow through normal AppKit event dispatch so the input method can
            // process it. Cmd-based shortcuts should still work during composition since
            // Cmd is never part of IME input sequences.
            if ghosttyView.hasMarkedText(), !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                return false
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                if AppDelegate.shared?.handleRoutableNumberedShortcutKeyEquivalent(event) == true {
                    return true
                }

                if event.modifierFlags.shouldDispatchTerminalArrowViaFirstResponderKeyDown(
                    keyCode: event.keyCode,
                    firstResponderIsTerminal: true,
                    firstResponderHasMarkedText: ghosttyView.hasMarkedText()
                ) {
                    if cmuxForceDispatchKeyDownOnce(event, to: ghosttyView, reason: "terminal arrow") {
                        return true
                    }
                    return false
                }

                let result = ghosttyView.performKeyEquivalent(with: event)
#if DEBUG
                cmuxDebugLog("  → ghostty direct: \(result)")
#endif
                return result
            }

            // Preserve Ghostty's terminal font-size shortcuts (Cmd +/−/0) when
            // the terminal is focused. Otherwise our browser menu shortcuts can
            // consume the event even when no browser panel is focused.
            if shouldRouteTerminalFontZoomShortcutToGhostty(
                firstResponderIsGhostty: true,
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                literalChars: event.characters
            ) {
                if cmuxForceDispatchKeyDownOnce(event, to: ghosttyView, reason: "terminal font zoom") {
#if DEBUG
                    cmuxDebugLog("zoom.shortcut stage=window.ghosttyKeyDownDirect event=\(event.cmuxKeyDescription) handled=1")
#endif
                    return true
                }
                return false
            }
        }

        if browserOmnibarShouldBypassShortcutRoutingForMarkedText(
            hasFocusedAddressBar: firstResponderOmnibarPanelId != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            guard let target = self.firstResponder,
                  cmuxForceDispatchKeyDownOnce(
                      event,
                      to: target,
                      reason: "browser omnibar marked-text " +
                          "panel=\(firstResponderOmnibarPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil")"
                  )
            else {
                return false
            }
            return true
        }

        if event.modifierFlags.shouldDispatchCommandPaletteHorizontalArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsCommandPaletteFieldEditor: firstResponderIsCommandPaletteFieldEditor,
            firstResponderHasMarkedText: firstResponderHasMarkedText
        ) {
            guard let target = self.firstResponder,
                  cmuxForceDispatchKeyDownOnce(event, to: target, reason: "command palette arrow")
            else {
                return false
            }
            return true
        }

        if shouldDispatchBrowserOmnibarArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowserOmnibar: firstResponderOmnibarPanelId != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            guard let target = self.firstResponder else { return false }
            if cmuxForceDispatchKeyDownOnce(
                event,
                to: target,
                reason: "browser omnibar arrow " +
                    "panel=\(firstResponderOmnibarPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil")"
            ) {
                return true
            }
            // Reentry of the same in-flight event: use normal dispatch.
            return cmux_performKeyEquivalent(with: event)
        }

        if event.modifierFlags.shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsTextBoxInput: firstResponderIsTextBoxInput,
            firstResponderHasMarkedText: firstResponderHasMarkedText
        ) {
            guard let target = self.firstResponder,
                  cmuxForceDispatchKeyDownOnce(event, to: target, reason: "text-box input arrow")
            else {
                return false
            }
            return true
        }

        if event.modifierFlags.shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: KeyboardLayout.normalizedCharacters(for: event),
            firstResponderIsTextBoxInput: firstResponderIsTextBoxInput,
            firstResponderHasMarkedText: firstResponderHasMarkedText
        ) {
            guard let target = self.firstResponder,
                  cmuxForceDispatchKeyDownOnce(event, to: target, reason: "text-box input control nav")
            else {
                return false
            }
            return true
        }

        // The file-preview editor and any other standalone editable NSTextView
        // would otherwise lose plain/selection/word/line arrows to the original
        // NSWindow.performKeyEquivalent. Route them to the text view's keyDown so
        // arrow navigation works as in any text editor (manaflow-ai/cmux#5227).
        if event.modifierFlags.shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsEditableTextView: firstResponderIsStandaloneEditableTextView,
            firstResponderHasMarkedText: firstResponderHasMarkedText
        ) {
            guard let target = self.firstResponder,
                  cmuxForceDispatchKeyDownOnce(event, to: target, reason: "editable text view arrow")
            else {
                return false
            }
            return true
        }

        // Web forms rely on Return/Enter flowing through keyDown. Route it directly to the first responder.
        if shouldDispatchBrowserReturnViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if browserWebKitKeyDownReentry { return false }
            guard let target = self.firstResponder else { return false }
            if cmuxForceDispatchKeyDownOnce(event, to: target, reason: "browser Return/Enter") {
                return true
            }
            // Forwarding keyDown can re-enter performKeyEquivalent in WebKit/AppKit internals.
            // On re-entry, fall back to normal dispatch to avoid an infinite loop.
            return cmux_performKeyEquivalent(with: event)
        }

        // Browser content can lose plain arrows when performKeyEquivalent claims them before WebKit.
        if shouldDispatchBrowserArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsBrowser: firstResponderWebView != nil,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            if browserWebKitKeyDownReentry { return false }
            if let focusedOmnibarField = AppDelegate.shared?.focusedBrowserOmnibarField(for: event, in: self),
               BrowserOmnibarNativeFieldRegistry.shared.omnibarPanelId(for: self.firstResponder) == nil,
               focusedOmnibarField.window === self {
                var currentEditorResponder: NSResponder? = focusedOmnibarField.currentEditor()
                if currentEditorResponder == nil || self.firstResponder !== currentEditorResponder {
                    guard self.makeFirstResponder(focusedOmnibarField) else {
#if DEBUG
                        cmuxDebugLog("  → browser arrow omnibar restore rejected")
#endif
                        return false
                    }
                    currentEditorResponder = focusedOmnibarField.currentEditor()
                }

                let omnibarResponder: NSResponder
                if let currentEditorResponder, self.firstResponder === currentEditorResponder {
                    omnibarResponder = currentEditorResponder
                } else if self.firstResponder === focusedOmnibarField {
                    omnibarResponder = focusedOmnibarField
                } else {
#if DEBUG
                    cmuxDebugLog("  → browser arrow omnibar restore did not become first responder")
#endif
                    return false
                }
                if cmuxForceDispatchKeyDownOnce(
                    event,
                    to: omnibarResponder,
                    reason: browserResponderHasMarkedText(omnibarResponder)
                        ? "browser arrow restored focused omnibar with marked text"
                        : "browser arrow restored focused omnibar"
                ) {
                    return true
                }
                // Reentry of the same in-flight event: use normal dispatch.
                return cmux_performKeyEquivalent(with: event)
            }

            // Match the Return/Enter forwarding guard: AppKit/WebKit can re-enter
            // performKeyEquivalent while the synthesized keyDown is in flight.
            guard let target = self.firstResponder else { return false }
            if cmuxForceDispatchKeyDownOnce(event, to: target, reason: "browser arrow") {
                return true
            }
            return cmux_performKeyEquivalent(with: event)
        }

        if let firstResponderWebView,
           AppDelegate.shared?.isBrowserFocusModeActive(for: firstResponderWebView) == true {
            let handled = firstResponderWebView.performKeyEquivalent(with: event)
#if DEBUG
            cmuxDebugLog("  → browser focus mode routed before cmux/menu fallback handled=\(handled ? 1 : 0)")
#endif
            return handled
        }

        if let firstResponderWebView,
           shouldRouteBrowserDocumentEditingCommandEquivalentThroughWebContentFirst(
               event,
               responder: self.firstResponder
           ) {
            let result = firstResponderWebView.performKeyEquivalent(with: event)
#if DEBUG
            cmuxDebugLog(
                "  → browser document editing command preflight " +
                (result ? "resolved before window menu path" : "left unclaimed; suppressing replay")
            )
#endif
            // The focused web view has already received this editing shortcut once.
            // `CmuxWebView.performKeyEquivalent` also runs the main-menu fallback
            // before returning, so falling through here would only replay WebKit.
            return true
        }

        if let firstResponderWebView,
           shouldRouteBrowserFindCommandEquivalentThroughWebContentFirst(
               event,
               responder: self.firstResponder,
               owningWebView: firstResponderWebView
           ) {
            let result = firstResponderWebView.performKeyEquivalent(with: event)
#if DEBUG
            if result {
                cmuxDebugLog("  → browser find command resolved before window menu path")
            } else {
                cmuxDebugLog("  → browser find command preflight left unclaimed; suppressing replay")
            }
#endif
            // The focused web view has already received this Find-family shortcut once.
            // Do not fall through into the original NSWindow.performKeyEquivalent path,
            // or WebKit can observe the same key equivalent a second time before AppKit
            // reaches keyDown/menu fallback.
            return true
        }

        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
#if DEBUG
            cmuxDebugLog("  → consumed by handleBrowserSurfaceKeyEquivalent")
#endif
            return true
        }

        if let firstResponderGhosttyView, shouldRouteCommandEquivalentDirectlyToMainMenu(event) {
            if AppDelegate.shared?.shouldForwardBrowserSurfaceShortcutToTerminal(event) == true {
                if firstResponderGhosttyView.performKeyEquivalentAfterMenuMiss(with: event) { return true }
                if cmuxForceDispatchKeyDownOnce(
                    event,
                    to: firstResponderGhosttyView,
                    reason: "browser surface shortcut to terminal"
                ) {
                    return true
                }
                return false
            }
            guard let mainMenu = NSApp.mainMenu else { return false }
            let consumedByMenu = mainMenu.performKeyEquivalent(with: event)
#if DEBUG
            if browserZoomShortcutTraceCandidate(
                flags: event.modifierFlags,
                chars: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode,
                literalChars: event.characters
            ) {
                cmuxDebugLog(
                    "zoom.shortcut stage=window.mainMenuBypass event=\(event.cmuxKeyDescription) " +
                    "consumed=\(consumedByMenu ? 1 : 0) fr=GhosttyNSView"
                )
            }
#endif
            if !consumedByMenu {
                // After a direct-to-menu miss, let Ghostty resolve the command key
                // through its normal binding path so user key overrides still win.
                let consumedByGhostty = firstResponderGhosttyView.performKeyEquivalentAfterMenuMiss(with: event)
#if DEBUG
                cmuxDebugLog("  → mainMenu miss; ghostty command path: \(consumedByGhostty)")
#endif
                if consumedByGhostty {
                    return true
                }
            } else {
#if DEBUG
                cmuxDebugLog("  → consumed by mainMenu (bypassed SwiftUI)")
#endif
                return true
            }
        }

        let result = cmux_performKeyEquivalent(with: event)
#if DEBUG
        if result { cmuxDebugLog("  → consumed by original performKeyEquivalent") }
#endif
        return result
    }

    private static func cmuxOwningWebView(for responder: NSResponder) -> CmuxWebView? {
        if let webView = responder as? CmuxWebView {
            return webView
        }

        if let view = responder as? NSView,
           let webView = cmuxOwningWebView(for: view) {
            return webView
        }

        // NSTextView.delegate is unsafe-unretained in AppKit. Reading it here while
        // a responder chain is tearing down can trap with "unowned reference".
        var current = responder.nextResponder
        while let next = current {
            if let webView = next as? CmuxWebView {
                return webView
            }
            if let view = next as? NSView,
               let webView = cmuxOwningWebView(for: view) {
                return webView
            }
            current = next.nextResponder
        }

        return nil
    }

    private static func cmuxOwningWebView(
        for responder: NSResponder,
        in window: NSWindow,
        event: NSEvent?
    ) -> CmuxWebView? {
        if BrowserOmnibarNativeFieldRegistry.shared.omnibarPanelId(for: responder) != nil {
            return nil
        }

        // Browser find runs in the portal slot alongside the hosted WKWebView.
        // Treat its native field editor chain as browser chrome, not as web content,
        // so Cmd+F can move first responder into the find field while web focus is suppressed.
        if BrowserWindowPortalRegistry.searchOverlayPanelId(for: responder, in: window) != nil {
            return nil
        }

        if let webView = cmuxOwningWebView(for: responder) {
            return webView
        }

        guard let textView = responder as? NSTextView, textView.isFieldEditor else {
            return nil
        }

        if let event,
           let hitWebView = cmuxPointerHitWebView(in: window, event: event) {
            cmuxTrackFieldEditor(textView, owningWebView: hitWebView)
            return hitWebView
        }

        return cmuxTrackedOwningWebView(for: textView)
    }

    private static func cmuxOwningWebView(for view: NSView) -> CmuxWebView? {
        if let webView = view as? CmuxWebView {
            return webView
        }

        var current: NSView? = view.superview
        while let candidate = current {
            if let webView = candidate as? CmuxWebView {
                return webView
            }
            if String(describing: type(of: candidate)).contains("WindowBrowserSlotView"),
               let portalWebView = cmuxUniqueBrowserWebView(in: candidate) {
                // Portal-hosted browser chrome (for example the Cmd+F overlay) is a
                // sibling of the hosted WKWebView inside WindowBrowserSlotView, not a
                // descendant of it. Allow native text-entry controls in that slot to
                // acquire first responder directly, but keep generic sibling views
                // associated with the hosted web view so blocked browser focus policy
                // still protects inspector/overlay chrome from stray focus changes.
                if view === portalWebView || view.isDescendant(of: portalWebView) {
                    return portalWebView
                }
                if cmuxAllowsPortalSlotTextEntryFocus(view) {
                    return nil
                }
                return portalWebView
            }
            current = candidate.superview
        }

        return nil
    }

    private static func cmuxAllowsPortalSlotTextEntryFocus(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if let textField = candidate as? NSTextField {
                return textField.isEditable || textField.acceptsFirstResponder
            }
            if let textView = candidate as? NSTextView {
                return textView.isEditable || textView.isSelectable || textView.isFieldEditor
            }
            current = candidate.superview
        }
        return false
    }

    private static func cmuxUniqueBrowserWebView(in root: NSView) -> CmuxWebView? {
        var stack: [NSView] = [root]
        var found: CmuxWebView?
        while let current = stack.popLast() {
            if let webView = current as? CmuxWebView {
                if found == nil {
                    found = webView
                } else if found !== webView {
                    return nil
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
    }

    private static func cmuxCurrentEvent(for window: NSWindow) -> NSEvent? {
#if DEBUG
        if let override = cmuxFirstResponderGuardCurrentEventOverride {
            return override
        }
#endif
        if cmuxFirstResponderGuardContextWindowNumber == window.windowNumber {
            return cmuxFirstResponderGuardCurrentEventContext
        }
        return NSApp.currentEvent
    }

    private static func cmuxHitViewInThemeFrame(in window: NSWindow, event: NSEvent) -> NSView? {
        guard let contentView = window.contentView,
              let themeFrame = contentView.superview else {
            return nil
        }
        let pointInTheme = themeFrame.convert(event.locationInWindow, from: nil)
        return themeFrame.hitTest(pointInTheme)
    }

    private static func cmuxHitViewInContentView(in window: NSWindow, event: NSEvent) -> NSView? {
        guard let contentView = window.contentView else {
            return nil
        }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(pointInContent)
    }

    private static func cmuxTopHitViewForEvent(in window: NSWindow, event: NSEvent) -> NSView? {
        if let hitInThemeFrame = cmuxHitViewInThemeFrame(in: window, event: event) {
            return hitInThemeFrame
        }
        return cmuxHitViewInContentView(in: window, event: event)
    }

    private static func cmuxHitViewForEventDispatch(in window: NSWindow, event: NSEvent) -> NSView? {
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return nil
        }
        if let eventWindow = event.window, eventWindow !== window {
            return nil
        }
        return cmuxTopHitViewForEvent(in: window, event: event)
    }

    private static func cmuxHitViewForFirstResponderGuard(in window: NSWindow, event: NSEvent) -> NSView? {
        guard WindowInputRoutingContext(event: event).allowsFirstResponderHitTesting else { return nil }
        return cmuxHitViewForEventDispatch(in: window, event: event)
    }

    private static func cmuxHitViewForCurrentEvent(in window: NSWindow, event: NSEvent) -> NSView? {
#if DEBUG
        if let override = cmuxFirstResponderGuardHitViewOverride {
            return override
        }
#endif
        if cmuxFirstResponderGuardContextWindowNumber == window.windowNumber,
           let contextHitView = cmuxFirstResponderGuardHitViewContext {
            return contextHitView
        }
        return cmuxTopHitViewForEvent(in: window, event: event)
    }

    private static func cmuxTrackFieldEditor(_ fieldEditor: NSTextView, owningWebView webView: CmuxWebView?) {
        // App-side responder-introspection shim: forward into the package
        // registry that retired the `cmuxFieldEditorOwningWebViewAssociationKey`
        // global. `CmuxWebView` is an app-target subclass of the package's
        // `WKWebView`-typed store.
        AppDelegate.shared?.browserFieldEditorOwnershipRegistry.setOwningWebView(
            webView,
            forFieldEditor: fieldEditor
        )
    }

    private static func cmuxTrackedOwningWebView(for fieldEditor: NSTextView) -> CmuxWebView? {
        AppDelegate.shared?
            .browserFieldEditorOwnershipRegistry
            .owningWebView(forFieldEditor: fieldEditor) as? CmuxWebView
    }

    private static func cmuxEventAllowsFirstResponderHitTesting(_ event: NSEvent) -> Bool {
        WindowInputRoutingContext(event: event).allowsFirstResponderHitTesting
    }

    private static func cmuxPointerEventTargetsWindow(_ event: NSEvent, _ window: NSWindow) -> Bool {
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return false
        }
        if let eventWindow = event.window, eventWindow !== window {
            return false
        }
        return true
    }

    private static func cmuxPointerHitWebView(in window: NSWindow, event: NSEvent) -> CmuxWebView? {
        guard cmuxEventAllowsFirstResponderHitTesting(event) else { return nil }
        guard cmuxPointerEventTargetsWindow(event, window) else { return nil }
        if let portalWebView = BrowserWindowPortalRegistry.webViewAtWindowPoint(
            event.locationInWindow,
            in: window
        ) as? CmuxWebView {
            return portalWebView
        }
        guard let hitView = cmuxHitViewForCurrentEvent(in: window, event: event) else {
            return nil
        }
        return cmuxOwningWebView(for: hitView)
    }

    private static func cmuxPointerHitGhosttyView(in window: NSWindow, event: NSEvent) -> GhosttyNSView? {
        guard cmuxEventAllowsFirstResponderHitTesting(event) else { return nil }
        guard cmuxPointerEventTargetsWindow(event, window) else { return nil }
        guard let hitView = cmuxHitViewForCurrentEvent(in: window, event: event) else {
            return nil
        }
        return cmuxOwningGhosttyView(for: hitView)
    }

    private static func cmuxShouldAllowPointerInitiatedTerminalFocus(
        window: NSWindow,
        request: AppDelegate.TerminalKeyboardFocusRequest,
        event: NSEvent?
    ) -> Bool {
        guard let event,
              let hitGhosttyView = cmuxPointerHitGhosttyView(in: window, event: event) else {
            return false
        }
        return hitGhosttyView === request.ghosttyView
    }

    private static func cmuxShouldAllowPointerInitiatedWebViewFocus(
        window: NSWindow,
        webView: CmuxWebView,
        event: NSEvent?
    ) -> Bool {
        guard let event,
              let hitWebView = cmuxPointerHitWebView(in: window, event: event) else {
            return false
        }
        return hitWebView === webView
    }

}

// MARK: - CmuxUpdater seams

/// Conforms the composition root to updater host actions, retry, and relaunch seams.
/// `checkForUpdatesInCustomUI()` is satisfied by the main `AppDelegate` declaration.
extension AppDelegate: UpdateActionDelegate, UpdateActionsHost {
    func updaterRequestsRetryCheckForUpdates() {
        checkForUpdates(nil)
    }

    func updaterWillRelaunchApplication() {
        persistSessionForUpdateRelaunch()
        terminalControl.stop()
        NSApp.invalidateRestorableState()
        for window in NSApp.windows {
            window.invalidateRestorableState()
        }
    }

    func attemptUpdate() {
        attemptUpdate(nil)
    }

    var updateLogPath: String {
        environment.updateLog.logPath()
    }
}

// MARK: - Window display placement (`window.display` / `window.displays`)

extension AppDelegate {
    /// Move every main window onto the display matched by `query`, preserving
    /// sizes. Returns the resolved display name and the moved window ids, or nil
    /// when the display can't be resolved. Compatibility forwarder to
    /// ``MainWindowRouter``.
    func moveAllMainWindows(toDisplayMatching query: String) -> (display: String, windowIds: [UUID])? {
        environment.mainWindowRouter.moveAllWindows(toDisplayMatching: query)
    }
}

// MARK: - CmuxAppKitSupportUI seam conformance

extension AppDelegate: WindowDecorating {}

// Backs the browser-debug panels' quick-action buttons (CmuxAppKitSupportUI).
// The panels live in the package; these three actions are the irreducible
// app-coupled live-state reach (Settings window, the live import dialog, and the
// import-hint debug defaults), inverted behind the `BrowserDebugContext` seam.
extension AppDelegate: BrowserDebugContext {
    func presentBrowserPreferences() {
        Self.presentPreferencesWindow(navigationTarget: .browser)
    }

    func presentBrowserImportDialog() {
        // Preserve the original one-runloop deferral so the import dialog is
        // presented after the debug-button action settles (behavior-faithful move).
        DispatchQueue.main.async {
            BrowserDataImportCoordinator.shared.presentImportDialog()
        }
    }

    func resetBrowserImportHintDebugState() {
        BrowserImportHintSettings().reset()
    }
}

// MARK: - CmuxWorkspaces session-autosave seam conformance

// `isTerminatingApp` (the per-tick termination guard) and
// `performScheduledAutosave(source:)` (the app-coupled snapshot save) are
// declared on `AppDelegate` above; the scheduler drives them through this seam.
extension AppDelegate: SessionAutosaveScheduling {}

// `toggleApplicationVisibilityFromGlobalHotkey()`,
// `toggleGlobalSearchPaletteFromGlobalHotkey()`, and
// `captureMainWindowVisibilityRestoreTargetsForApplicationHide()` are declared on
// `AppDelegate` above; `SystemWideHotkeyController` invokes them through this
// injected seam instead of reaching back through the `AppDelegate.shared` singleton.
extension AppDelegate: SystemWideHotkeyActionHandling {}

#if DEBUG
// MARK: - CmuxTestSupport diagnostics seam conformance

extension AppDelegate: UITestDiagnosticsProviding {}

// MARK: - CmuxTestSupport recorder-install seam conformance

extension AppDelegate: UITestRecorderInstalling {
    /// The launch-time recorders, built and cached in the legacy install order
    /// (jump-unread, terminal cmd-click, goto-split, bonsplit tab-drag). Each is
    /// the same cached instance the live notification/navigation hooks write
    /// through, so installing here arms exactly the recorders those hooks record
    /// into. `feedSidebar`, the multi-window scaffold, the terminal-viewport
    /// recorder, and the diagnostics observers are installed from their own
    /// lifecycle points (deferred feed-store readiness, distinct shape) and so
    /// stay out of this batch.
    var launchUITestRecorders: [any UITestRecording] {
        let jumpUnread = jumpUnreadUITestRecorder ?? JumpUnreadUITestRecorder(appDelegate: self)
        jumpUnreadUITestRecorder = jumpUnread
        let terminalCmdClick = terminalCmdClickUITestRecorder ?? TerminalCmdClickUITestRecorder(appDelegate: self)
        terminalCmdClickUITestRecorder = terminalCmdClick
        let gotoSplit = gotoSplitUITestRecorder ?? GotoSplitUITestRecorder(appDelegate: self)
        gotoSplitUITestRecorder = gotoSplit
        let bonsplitTabDrag = bonsplitTabDragUITestRecorder ?? BonsplitTabDragUITestRecorder(appDelegate: self)
        bonsplitTabDragUITestRecorder = bonsplitTabDrag
        return [jumpUnread, terminalCmdClick, gotoSplit, bonsplitTabDrag]
    }
}

// MARK: - CmuxTestSupport launch-scaffold seam conformance

// The live launch actions ``StartupUITestScaffold`` sequences. They touch `NSApp`
// windows, the Sparkle update controller / log, the browser import-hint
// `UserDefaults` keys, the browser address bar, the preferences window, and the
// browser-data import dialog, all of which are app-target state, so the bodies
// stay here and the scaffold (CmuxTestSupport) owns the gates + schedule.
extension AppDelegate: StartupUITestScaffoldDriving {
    func applyUpdateTestSupport() {
        UpdateTestSupport(model: updateController.model, log: environment.updateLog).applyIfNeeded()
    }

    func logUpdateTestEnvironment(trigger: String, feed: String) {
        environment.updateLog.append("ui test env: trigger=\(trigger) feed=\(feed)")
    }

    func logTriggerUpdateCheckDetected() {
        environment.updateLog.append("ui test trigger update check detected")
    }

    func performTriggerUpdateCheck() {
        let windowIds = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
        environment.updateLog.append("ui test windows: count=\(NSApp.windows.count) ids=\(windowIds.joined(separator: ","))")
        if UpdateTestSupport(model: updateController.model, log: environment.updateLog).performMockFeedCheckIfNeeded() {
            return
        }
        checkForUpdates(nil)
    }

    func applyBrowserImportHintDefaults(variant: String?, show: String?, dismissed: String?) {
        if let rawVariant = variant {
            UserDefaults.standard.set(
                BrowserImportHintSettings.variant(for: rawVariant).rawValue,
                forKey: BrowserImportHintSettings.variantKey
            )
        }
        if let rawShow = show {
            UserDefaults.standard.set(
                rawShow == "1",
                forKey: BrowserImportHintSettings.showOnBlankTabsKey
            )
        }
        if let rawDismissed = dismissed {
            UserDefaults.standard.set(
                rawDismissed == "1",
                forKey: BrowserImportHintSettings.dismissedKey
            )
        }
    }

    func forceMainWindowAndActivate() {
        if NSApp.windows.isEmpty {
            openNewMainWindow(nil)
        }
        moveUITestWindowToTargetDisplayIfNeeded()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        // On headless CI runners, activate() silently fails (no GUI session).
        // Force windows visible so the terminal surface starts rendering.
        for window in NSApp.windows {
            window.orderFrontRegardless()
        }
    }

    func openBlankBrowserAndFocusAddressBar() {
        _ = openBrowserAndFocusAddressBar(insertAtEnd: true)
    }

    func openBrowserImportSettings() {
        openPreferencesWindow(
            debugSource: "uiTest.browserImportHint",
            navigationTarget: .browser
        )
    }
}
#endif
