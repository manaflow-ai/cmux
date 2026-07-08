import AppKit
import CmuxAppKitSupportUI
import CmuxAuthRuntime
import CmuxBrowser
import CmuxCommandPalette
import CmuxPanes
import CmuxControlSocket
import CmuxWindowing
import CmuxNotifications
import CmuxTerminalCore
import CmuxTerminal
import CmuxSettings
import CmuxSettingsUI
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

private enum CmuxThemeNotifications {
    static let reloadConfig = Notification.Name("com.cmuxterm.themes.reload-config")
}

private struct WorkspaceGroupNewWorkspaceTarget {
    let groupId: UUID
    let referenceWorkspaceId: UUID
    let placement: WorkspaceGroupNewPlacement
}

/// Short-lived helper that watches for the next workspace to appear in a
/// TabManager and joins it to a target group. Used by group `+` context-menu
/// actions whose underlying executor creates the workspace asynchronously
/// (cloudVM in particular launches `cmux vm base open` and returns immediately).
/// Subscribes to `tabManager.tabsPublisher` (the legacy Combine bridge fed by
/// every `tabs` mutation, regardless of whether a NotificationCenter event
/// fired) so VM workspaces, dropped attaches, or any other slow async path
/// is caught. Self-clears on first match, group disappearance, or a process
/// completion signal that either names the created workspace or reports launch
/// failure.
@MainActor
final class ConfiguredGroupActionAsyncWorkspaceObserver {
    static var pending: [ObjectIdentifier: ConfiguredGroupActionAsyncWorkspaceObserver] = [:]
    private let id = UUID()
    private weak var tabManager: TabManager?
    private let storedKey: ObjectIdentifier
    private let groupId: UUID
    private let placement: WorkspaceGroupNewPlacement
    private let referenceWorkspaceId: UUID?
    private var knownIds: Set<UUID>
    private var subscription: AnyCancellable?

    @discardableResult
    static func install(
        tabManager: TabManager,
        groupId: UUID,
        knownIds: Set<UUID>,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?
    ) -> UUID {
        let key = ObjectIdentifier(tabManager)
        pending[key]?.dispose()
        let watcher = ConfiguredGroupActionAsyncWorkspaceObserver(
            tabManager: tabManager,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId,
            knownIds: knownIds
        )
        pending[key] = watcher
        watcher.subscription = tabManager.tabsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak watcher] tabs in
                watcher?.checkForNewWorkspace(in: tabs)
            }
        return watcher.id
    }

    static func disposePending(tabManager: TabManager, observerId: UUID) {
        let key = ObjectIdentifier(tabManager)
        guard pending[key]?.id == observerId else { return }
        pending[key]?.dispose()
    }

    static func finishPending(tabManager: TabManager, observerId: UUID, workspaceId: UUID?) {
        let key = ObjectIdentifier(tabManager)
        guard let watcher = pending[key], watcher.id == observerId else { return }
        watcher.finish(workspaceId: workspaceId)
    }

    private init(
        tabManager: TabManager,
        groupId: UUID,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?,
        knownIds: Set<UUID>
    ) {
        self.tabManager = tabManager
        self.storedKey = ObjectIdentifier(tabManager)
        self.groupId = groupId
        self.placement = placement
        self.referenceWorkspaceId = referenceWorkspaceId
        self.knownIds = knownIds
    }

    private func checkForNewWorkspace(in tabs: [Workspace]) {
        guard let tabManager else { dispose(); return }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupId }) else {
            dispose()
            return
        }
        for tab in tabs where !knownIds.contains(tab.id) {
            tabManager.addWorkspaceToGroup(
                workspaceId: tab.id,
                groupId: groupId,
                placement: placement,
                referenceWorkspaceId: referenceWorkspaceId
            )
            dispose()
            return
        }
    }

    private func finish(workspaceId: UUID?) {
        defer { dispose() }
        guard let workspaceId, let tabManager else { return }
        guard tabManager.workspaceGroups.contains(where: { $0.id == groupId }) else { return }
        guard tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return }
        tabManager.addWorkspaceToGroup(
            workspaceId: workspaceId,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId
        )
    }

    private func dispose() {
        subscription?.cancel()
        subscription = nil
        // Remove by the key recorded at install time. The weak `tabManager`
        // may already be nil here (window closed mid-watch), and walking it
        // would silently leak the entry in the static `pending` dictionary
        // for the rest of the app session.
        Self.pending.removeValue(forKey: storedKey)
    }
}

#if DEBUG
enum CmuxTypingTiming {
    static let isEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_TYPING_TIMING_LOGS"] == "1" || environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "cmuxTypingTimingLogs") || defaults.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    static let isVerboseProbeEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_KEY_LATENCY_PROBE"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()
    private static let delayLogThresholdMs: Double = 6.0
    private static let durationLogThresholdMs: Double = 1.0

    @inline(__always)
    static func start() -> TimeInterval? {
        guard isEnabled else { return nil }
        return ProcessInfo.processInfo.systemUptime
    }

    @inline(__always)
    static func logEventDelay(path: String, event: NSEvent) {
        guard isEnabled else { return }
        guard event.timestamp > 0 else { return }
        let delayMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        guard shouldLog(delayMs: delayMs, elapsedMs: nil) else { return }
        cmuxDebugLog("typing.delay path=\(path) delayMs=\(format(delayMs)) \(eventFields(event))")
    }

    @inline(__always)
    static func logDuration(path: String, startedAt: TimeInterval?, event: NSEvent? = nil, extra: String? = nil) {
        CmuxMainThreadTurnProfiler.endMeasure(path, startedAt: startedAt)
        guard let startedAt else { return }
        let elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0)
        let delayMs: Double? = {
            guard let event, event.timestamp > 0 else { return nil }
            return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        }()
        guard shouldLog(delayMs: delayMs, elapsedMs: elapsedMs) else { return }
        var line = "typing.timing path=\(path) elapsedMs=\(format(elapsedMs))"
        if let event {
            line += " \(eventFields(event))"
            if let delayMs {
                line += " delayMs=\(format(delayMs))"
            }
        }
        if let extra, !extra.isEmpty {
            line += " \(extra)"
        }
        cmuxDebugLog(line)
    }

    @inline(__always)
    static func logBreakdown(
        path: String,
        totalMs: Double,
        event: NSEvent? = nil,
        thresholdMs: Double = 2.0,
        parts: [(String, Double)],
        extra: String? = nil
    ) {
        guard isEnabled else { return }
        let delayMs: Double? = {
            guard let event, event.timestamp > 0 else { return nil }
            return max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000.0)
        }()
        let hasSlowPart = parts.contains { $0.1 >= thresholdMs }
        guard isVerboseProbeEnabled || totalMs >= thresholdMs || hasSlowPart || (delayMs ?? 0) >= delayLogThresholdMs else {
            return
        }
        var line = "typing.phase path=\(path) totalMs=\(format(totalMs))"
        if let event {
            line += " \(eventFields(event))"
        }
        if let delayMs {
            line += " delayMs=\(format(delayMs))"
        }
        for (name, value) in parts where isVerboseProbeEnabled || value >= 0.05 {
            line += " \(name)=\(format(value))"
        }
        if let extra, !extra.isEmpty {
            line += " \(extra)"
        }
        cmuxDebugLog(line)
    }

    @inline(__always)
    private static func eventFields(_ event: NSEvent) -> String {
        "eventType=\(event.type.rawValue) keyCode=\(event.keyCode) mods=\(event.modifierFlags.rawValue) repeat=\(event.isARepeat ? 1 : 0)"
    }

    @inline(__always)
    private static func shouldLog(delayMs: Double?, elapsedMs: Double?) -> Bool {
        if isVerboseProbeEnabled {
            return true
        }
        if let delayMs, delayMs >= delayLogThresholdMs {
            return true
        }
        if let elapsedMs, elapsedMs >= durationLogThresholdMs {
            return true
        }
        return false
    }

    @inline(__always)
    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

final class CmuxMainRunLoopStallMonitor {
    static let shared = CmuxMainRunLoopStallMonitor()

    private let thresholdMs: Double = 8.0
    private var observer: CFRunLoopObserver?
    private var installed = false
    private var lastActivity: CFRunLoopActivity?
    private var lastTimestamp: TimeInterval?

    private init() {}

    func installIfNeeded() {
        guard CmuxTypingTiming.isEnabled else { return }
        guard !installed else { return }

        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            CFIndex.max,
            { _, activity, info in
                guard let info else { return }
                let monitor = Unmanaged<CmuxMainRunLoopStallMonitor>.fromOpaque(info).takeUnretainedValue()
                monitor.handle(activity: activity)
            },
            &context
        )

        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        installed = true
    }

    private func handle(activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            lastActivity = activity
            lastTimestamp = now
        }

        guard let lastActivity, let lastTimestamp else { return }
        let elapsedMs = max(0, (now - lastTimestamp) * 1000.0)
        guard elapsedMs >= thresholdMs else { return }
        if lastActivity == .beforeWaiting && activity == .afterWaiting {
            return
        }

        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { String(describing: $0) } ?? "nil"
        let firstResponder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let currentEvent = NSApp.currentEvent.map {
            "eventType=\($0.type.rawValue) keyCode=\($0.keyCode) mods=\($0.modifierFlags.rawValue)"
        } ?? "event=nil"
        cmuxDebugLog(
            "runloop.stall gapMs=\(String(format: "%.2f", elapsedMs)) prev=\(label(for: lastActivity)) " +
            "next=\(label(for: activity)) mode=\(mode) firstResponder=\(firstResponder) \(currentEvent)"
        )
    }

    private func label(for activity: CFRunLoopActivity) -> String {
        switch activity {
        case .entry:
            return "entry"
        case .beforeTimers:
            return "beforeTimers"
        case .beforeSources:
            return "beforeSources"
        case .beforeWaiting:
            return "beforeWaiting"
        case .afterWaiting:
            return "afterWaiting"
        case .exit:
            return "exit"
        default:
            return "unknown(\(activity.rawValue))"
        }
    }
}

final class CmuxMainThreadTurnProfiler {
    static let shared = CmuxMainThreadTurnProfiler()

    private struct BucketStats {
        var count: Int = 0
        var totalMs: Double = 0
        var maxMs: Double = 0
    }

    private let trackedThresholdMs: Double = 3.0
    private let countThreshold: Int = 16
    private var observer: CFRunLoopObserver?
    private var installed = false
    private var turnStart: TimeInterval?
    private var buckets: [String: BucketStats] = [:]

    private init() {}

    @inline(__always)
    static func endMeasure(_ bucket: String, startedAt: TimeInterval?) {
        guard let startedAt, CmuxTypingTiming.isEnabled, Thread.isMainThread else { return }
        let elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0)
        shared.record(bucket: bucket, elapsedMs: elapsedMs, count: 1)
    }

    func installIfNeeded() {
        guard CmuxTypingTiming.isEnabled else { return }
        guard !installed else { return }

        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            CFIndex.max,
            { _, activity, info in
                guard let info else { return }
                let profiler = Unmanaged<CmuxMainThreadTurnProfiler>.fromOpaque(info).takeUnretainedValue()
                profiler.handle(activity: activity)
            },
            &context
        )

        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        installed = true
    }

    private func handle(activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        switch activity {
        case .entry, .afterWaiting:
            turnStart = now
            buckets.removeAll(keepingCapacity: true)
        case .beforeWaiting, .exit:
            flushTurn(at: now, nextActivity: activity)
        default:
            break
        }
    }

    private func record(bucket: String, elapsedMs: Double, count: Int) {
        if turnStart == nil {
            turnStart = ProcessInfo.processInfo.systemUptime
        }
        var stats = buckets[bucket, default: BucketStats()]
        stats.count += count
        stats.totalMs += elapsedMs
        stats.maxMs = max(stats.maxMs, elapsedMs)
        buckets[bucket] = stats
    }

    private func flushTurn(at now: TimeInterval, nextActivity: CFRunLoopActivity) {
        defer {
            turnStart = nil
            buckets.removeAll(keepingCapacity: true)
        }

        guard let turnStart else { return }
        guard !buckets.isEmpty else { return }

        let turnMs = max(0, (now - turnStart) * 1000.0)
        let trackedMs = buckets.values.reduce(0) { $0 + $1.totalMs }
        let totalCount = buckets.values.reduce(0) { $0 + $1.count }
        guard trackedMs >= trackedThresholdMs || totalCount >= countThreshold else { return }

        let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { String(describing: $0) } ?? "nil"
        let firstResponder = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let eventSummary = NSApp.currentEvent.map {
            "eventType=\($0.type.rawValue) keyCode=\($0.keyCode) mods=\($0.modifierFlags.rawValue)"
        } ?? "event=nil"
        let bucketSummary = buckets
            .sorted {
                if abs($0.value.totalMs - $1.value.totalMs) > 0.01 {
                    return $0.value.totalMs > $1.value.totalMs
                }
                return $0.value.count > $1.value.count
            }
            .prefix(8)
            .map { key, value in
                if value.totalMs > 0.05 || value.maxMs > 0.05 {
                    return "\(key)=\(value.count)/\(String(format: "%.2f", value.totalMs))/\(String(format: "%.2f", value.maxMs))"
                }
                return "\(key)=\(value.count)"
            }
            .joined(separator: " ")

        cmuxDebugLog(
            "main.turn.work turnMs=\(String(format: "%.2f", turnMs)) trackedMs=\(String(format: "%.2f", trackedMs)) totalCount=\(totalCount) " +
            "next=\(label(for: nextActivity)) mode=\(mode) firstResponder=\(firstResponder) \(eventSummary) " +
            "\(bucketSummary)"
        )
    }

    private func label(for activity: CFRunLoopActivity) -> String {
        switch activity {
        case .entry:
            return "entry"
        case .beforeTimers:
            return "beforeTimers"
        case .beforeSources:
            return "beforeSources"
        case .beforeWaiting:
            return "beforeWaiting"
        case .afterWaiting:
            return "afterWaiting"
        case .exit:
            return "exit"
        default:
            return "unknown(\(activity.rawValue))"
        }
    }
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuItemValidation, NSMenuDelegate, CmuxConfigStoreReloadEnvironment {
    nonisolated(unsafe) static var shared: AppDelegate?
    /// Stateless control-socket syscall layer (CmuxControlSocket); composition-root owned.
    nonisolated let socketTransport = SocketTransport()
    /// Owns the About Titlebar Debug subsystem (CmuxAppKitSupportUI); composition-root
    /// owned and created lazily so the window-decoration seam can point back at `self`.
    lazy var debugWindowsCoordinator = DebugWindowsCoordinator(decorator: self)
    /// About Titlebar Debug options store, applied by the About/Acknowledgments windows.
    var aboutTitlebarDebugStore: AboutTitlebarDebugStore { debugWindowsCoordinator.aboutTitlebarStore }
    /// Coordinates remote tmux (`ssh … tmux -CC`) mirroring; composition-root owned.
    let remoteTmuxController = RemoteTmuxController()
    private static let reloadConfigurationMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.cmux.reloadConfiguration")

    private static let cachedIsRunningUnderXCTest = detectRunningUnderXCTest(ProcessInfo.processInfo.environment)
    private var isRunningUnderXCTestCached: Bool {
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

    @MainActor
    final class MainWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let sidebarState: SidebarState
        let sidebarSelectionState: SidebarSelectionState
        var fileExplorerState: FileExplorerState?
        let keyboardFocusCoordinator: MainWindowFocusController
        var cmuxConfigStore: CmuxConfigStore?
        var closeObserver: WindowCloseObserver?
        weak var window: NSWindow?
        /// Per-window Dock owned by this context and torn down with it.
        var windowDock: DockSplitStore?

        init(
            windowId: UUID,
            tabManager: TabManager,
            sidebarState: SidebarState,
            sidebarSelectionState: SidebarSelectionState,
            fileExplorerState: FileExplorerState?,
            cmuxConfigStore: CmuxConfigStore?,
            window: NSWindow?
        ) {
            self.windowId = windowId
            self.tabManager = tabManager
            self.sidebarState = sidebarState
            self.sidebarSelectionState = sidebarSelectionState
            self.fileExplorerState = fileExplorerState
            self.cmuxConfigStore = cmuxConfigStore
            self.window = window
            self.keyboardFocusCoordinator = MainWindowFocusController(
                windowId: windowId,
                window: window,
                tabManager: tabManager,
                fileExplorerState: fileExplorerState
            )
        }
    }

    private final class MainWindowController: NSWindowController, NSWindowDelegate {
        var onClose: (() -> Void)?
        var shouldClose: (() -> Bool)?

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

    struct PersistedWindowGeometry: Codable, Sendable {
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

    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    weak var sidebarState: SidebarState?

    /// Notification jump/open navigation, extracted into `CmuxNotifications`.
    /// `AppDelegate` is the composition root: it conforms to every seam (see
    /// `AppDelegate+NotificationNavSeams.swift`) and injects itself. Built lazily
    /// because the seams read late-bound state (`notificationStore`,
    /// `mainWindowContexts`) that is `nil` until startup wiring completes; the
    /// seam contracts already degrade to empty/no-op when that state is absent.
    /// Performs notification click actions (currently reveal-in-Finder). The
    /// path-resolution logic lives in the package; `AppDelegate` only supplies
    /// the `NSWorkspace`/`FileManager` side effect through `FinderRevealing`. The
    /// single instance is shared by both the navigation coordinator and the
    /// `UNUserNotificationCenter` delivery coordinator.
    /// Weak-owner adapter that satisfies every notification-nav seam by
    /// forwarding to `AppDelegate` helpers. The coordinator and click performer
    /// strong-ref this adapter; the adapter weak-refs `AppDelegate`, so there is
    /// no `AppDelegate → coordinator → AppDelegate` retain cycle (which would pin
    /// the app-host test instance). See `AppDelegate+NotificationNavSeams.swift`.
    lazy var notificationNavSeams = NotificationNavSeamAdapter(owner: self)

    lazy var notificationClickPerformer = NotificationClickPerformer(finder: notificationNavSeams)

    lazy var notificationNavigation: NotificationNavigationCoordinator =
        NotificationNavigationCoordinator(
            store: notificationNavSeams,
            windows: notificationNavSeams,
            unreadTargeting: notificationNavSeams,
            openRouting: notificationNavSeams,
            clickRouting: notificationClickPerformer,
            focusedResolving: notificationNavSeams,
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
    // The open-routing trio (`openNotification` / `openNotificationInContext` /
    // `openNotificationFallback`) intentionally stays in `AppDelegate`, reached
    // through the open-routing seam (`openRouted` / `openInWindow` /
    // `openInActiveWindowFallback`). Those three methods weave ~15 branch-specific
    // `#if DEBUG` jump-unread UI-test recorder payloads through their control flow
    // (per early-return and per success path); re-homing them as injected closures
    // could not preserve byte-identical payloads/ordering without risking a
    // changed or duplicated payload that the jump-unread XCUITest asserts on, so
    // they are left app-side per the wave brief's escape hatch. The coordinator's
    // `onDidFocusForJumpUnread` hook is therefore left unwired (wiring it would
    // double-record). The recorder-FREE members of the open/click cluster did
    // move into the package this wave: the reveal-in-Finder side effect now lives
    // in `NotificationClickPerformer` (behind `FinderRevealing`), and the entire
    // focused-mark state machine lives in `FocusedNotificationMarker` (behind
    // `FocusedNotificationResolving`).
    /// The auth graph, injected once via `configure(...)` at app startup.
    private(set) var auth: MacAuthComposition?
    /// Strongly-held observers for every active TabManager. Each observer owns
    /// Combine subscriptions that publish workspace.updated to mobile clients.
    private var mobileWorkspaceListObservers: [ObjectIdentifier: MobileWorkspaceListObserver] = [:]
    private let agentChatTranscriptService = AgentChatTranscriptService()
    /// The app's settings dependency container, handed over by `cmuxApp` via
    /// `configure(...)` before any main window is created. AppKit builds the
    /// main window's `NSHostingView` itself, so it injects this into the
    /// `ContentView` environment so `@LiveSetting` can resolve the stores it
    /// observes inside the sidebar.
    var settingsRuntime: SettingsRuntime?
    weak var fileExplorerState: FileExplorerState?
    weak var fullscreenControlsViewModel: TitlebarControlsViewModel?
    weak var sidebarSelectionState: SidebarSelectionState?
    var shortcutLayoutCharacterProvider: (UInt16, NSEvent.ModifierFlags) -> String? = KeyboardLayout.character(forKeyCode:modifierFlags:)
    private var workspaceObserver: NSObjectProtocol?
    private var lifecycleSnapshotObservers: [NSObjectProtocol] = []
    private var windowKeyObservers: [NSObjectProtocol] = []
    private var shortcutMonitor: Any?
    private var shortcutDefaultsObserver: NSObjectProtocol?
    private var menuBarVisibilityObserver: NSObjectProtocol?
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
    private var ghosttyCrashBreadcrumbTask: Task<Void, Never>?
    private struct PendingConfiguredShortcutChord {
        let firstStroke: ShortcutStroke
        let windowNumber: Int?
    }
    private var pendingConfiguredShortcutChord: PendingConfiguredShortcutChord?
    var activeConfiguredShortcutChordPrefixForCurrentEvent: ShortcutStroke?
    var shortcutEventFocusContextCache: ShortcutEventFocusContextCache?
    private var ghosttyConfigObserver: NSObjectProtocol?
    private var globalFontMagnificationObserver: NSObjectProtocol?
    private var ghosttyGotoSplitLeftShortcut: StoredShortcut?
    private var ghosttyGotoSplitRightShortcut: StoredShortcut?
    private var ghosttyGotoSplitUpShortcut: StoredShortcut?
    private var ghosttyGotoSplitDownShortcut: StoredShortcut?
    private var browserAddressBarFocusedPanelId: UUID?
    /// Owns the browser omnibar selection-repeat state machine, extracted into
    /// `CmuxBrowser`. The app delegate is the composition root: it injects
    /// the `NotificationCenter` selection-move sink and the debug-trace sink.
    private lazy var browserOmnibarSelectionRepeat: BrowserOmnibarSelectionRepeatCoordinator = {
        let debugLog: BrowserOmnibarSelectionRepeatCoordinator.DebugLog?
#if DEBUG
        debugLog = { line in cmuxDebugLog(line) }
#else
        debugLog = nil
#endif
        return BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: { panelId, delta in
                NotificationCenter.default.post(
                    name: .browserMoveOmnibarSelection,
                    object: panelId,
                    userInfo: ["delta": delta]
                )
            },
            debugLog: debugLog
        )
    }()
    private var browserAddressBarFocusObserver: NSObjectProtocol?
    private var browserAddressBarBlurObserver: NSObjectProtocol?
    private var browserWebViewFirstResponderObserver: NSObjectProtocol?
    let updateLog = UpdateLogStore()
    let focusLog = FocusLogStore()
    /// Process-wide identity of the workspace currently being sidebar-dragged in
    /// any window. Owned here (the composition root) and injected into every
    /// window's `SidebarDragState` so cross-window drops resolve a single drag.
    // TODO(de-singletonize): move SidebarWorkspaceDragRegistry off AppDelegate.shared when AppDelegate is decomposed.
    let sidebarWorkspaceDragRegistry = SidebarWorkspaceDragRegistry()
    #if DEBUG
    /// Debug-only registry mapping each mounted sidebar's window id to its live
    /// `SidebarDragState`, read by the `debug.sidebar.simulate_drag` handler.
    // TODO(de-singletonize): move SidebarDragStateRegistry off AppDelegate.shared when AppDelegate is decomposed.
    let sidebarDragStateRegistry = SidebarDragStateRegistry()
    var debugFocusedTerminalKeyRepairObserverForTesting: ((NSWindow, NSEvent, NSResponder?) -> Void)?
    #endif
    private lazy var updateController = UpdateController(log: updateLog)
    private lazy var titlebarAccessoryController = UpdateTitlebarAccessoryController(updateLog: updateLog, settingsRuntime: settingsRuntime)
    private let windowDecorationsController = WindowDecorationsController()
    private var menuBarExtraController: MenuBarExtraController?
    private var transientGlobalSearchMenuBarExtraController: MenuBarExtraController?
    private var lastMenuBarExtraShouldInstall: Bool?
    private lazy var mainWindowVisibilityController = MainWindowVisibilityController(
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
        let originalSelector = #selector(NSApplication.accessibilityAttributeValue(_:))
        let swizzledSelector = #selector(NSApplication.cmux_accessibilityAttributeValue(_:))
        guard let originalMethod = class_getInstanceMethod(targetClass, originalSelector),
              let swizzledMethod = class_getInstanceMethod(targetClass, swizzledSelector) else {
            return
        }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()

    /// Live `cmux diff` viewer subprocesses, keyed by pid, retained until they exit.
    /// Declared outside `#if DEBUG` because process retention is production behavior.
    private var diffViewerProcesses: [Int32: Process] = [:]
    /// In-flight agent-aware diff launches, keyed so repeated shortcuts do not fan out large baseline parses.
    var openDiffViewerAgentContextTasks: [String: Task<Void, Never>] = [:]
    var openDiffViewerAgentContextPendingRequests: [String: OpenDiffViewerAgentContextRequest] = [:]

#if DEBUG
    private var didSetupJumpUnreadUITest = false
    private var jumpUnreadFocusExpectation: (tabId: UUID, surfaceId: UUID)?
    private var jumpUnreadFocusObserver: NSObjectProtocol?
    private var didSetupTerminalCmdClickUITest = false
    private var didSetupGotoSplitUITest = false
    private var didSetupBonsplitTabDragUITest = false
    private var didSetupTerminalViewportUITest = false
    private var terminalCmdClickUITestPoller: DispatchSourceTimer?
    private var bonsplitTabDragUITestRecorder: DispatchSourceTimer?
    private var terminalViewportUITestRecorder: TerminalViewportUITestRecorder?
    private var gotoSplitUITestRecorder: DispatchSourceTimer?
    private var gotoSplitUITestObservers: [NSObjectProtocol] = []
    private var didSetupMultiWindowNotificationsUITest = false
    private var didSetupDisplayResolutionUITestDiagnostics = false
    private var displayResolutionUITestObservers: [NSObjectProtocol] = []
    private var didSetupFeedSidebarUITest = false
    private var didStartFeedSidebarUITestPush = false
    private var feedSidebarUITestObservers: [NSObjectProtocol] = []
    private var didSetupPortalStatsUITestDiagnostics = false
    private var portalStatsUITestObservers: [NSObjectProtocol] = []
    private struct UITestRenderDiagnosticsSnapshot {
        let panelId: UUID
        let drawCount: Int
        let presentCount: Int
        let lastPresentTime: Double
        let windowVisible: Bool
        let appIsActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }
    var debugCloseMainWindowConfirmationHandler: ((NSWindow) -> Bool)?
    /// Test seam: when set, ``openDiffViewerForFocusedWorkspace(for:)`` invokes this
    /// instead of spawning the bundled `cmux diff` CLI, so shortcut-dispatch tests can
    /// assert routing without launching a subprocess.
    var debugOpenDiffViewerHandler: (() -> Void)?
    var debugCreateMainWindowSourceIsNativeFullScreenOverride: Bool?
    // Keep debug-only windows alive when tests intentionally inject key mismatches.
    private var debugDetachedContextWindows: [NSWindow] = []

    private func childExitKeyboardProbePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func childExitKeyboardProbeHex(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars
            .map { String(format: "%04X", $0.value) }
            .joined(separator: ",")
    }

    private func writeChildExitKeyboardProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
        guard let path = childExitKeyboardProbePath() else { return }
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, by) in increments {
            let current = Int(payload[key] ?? "") ?? 0
            payload[key] = String(current + by)
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
#endif

    var mainWindowContexts: [ObjectIdentifier: MainWindowContext] = [:]
    private var mainWindowControllers: [MainWindowController] = []

    /// Tracks the cascade point for new windows, matching Ghostty's upstream algorithm.
    /// Reset to `.zero` so the first window seeds the point from its own position.
    private var lastCascadePoint = NSPoint.zero
    private(set) var startupSessionSnapshot: AppSessionSnapshot?
    private var didPrepareStartupSessionSnapshot = false
    var didAttemptStartupSessionRestore = false
    var isApplyingSessionRestore = false
    /// Durable navigation links that arrived before startup restore registered
    /// their target workspaces.
    var pendingStartupNavigationURLRequests: [CmuxNavigationURLRequest] = []
    private var sessionAutosaveTimer: DispatchSourceTimer?
    private var sessionAutosaveTickInFlight = false
    private var sessionAutosaveDeferredRetryPending = false
    private var processDetectedSessionSaveGeneration: UInt64 = 0
    private let sessionPersistenceQueue = DispatchQueue(
        label: "com.cmuxterm.app.sessionPersistence",
        qos: .utility
    )
    /// Session snapshot persistence (CmuxSession); composition-root owned.
    /// `nonisolated` because the autosave write block runs on `sessionPersistenceQueue`.
    nonisolated let sessionSnapshotStore: any SessionSnapshotStoring<AppSessionSnapshot> = SessionSnapshotRepository(
        schemaVersion: SessionSnapshotSchema.currentVersion,
        bundleIdentifier: Bundle.main.bundleIdentifier
    )
    /// Accessibility window-hierarchy cache (CmuxWindowing); composition-root
    /// owned. The `NSApplication` AX swizzle forwards to it behind
    /// ``AccessibilityWindowCaching``.
    /// `nonisolated(unsafe)`: the existential is non-Sendable, but it is only
    /// touched from the main-actor AX swizzle path (callers hold it on main),
    /// matching the other non-Sendable composition-root members (`shared`).
    nonisolated(unsafe) let accessibilityWindowCache: any AccessibilityWindowCaching = AccessibilityWindowCache()
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
    private var lastTypingActivityAt: TimeInterval = 0
    var didHandleExplicitOpenIntentAtStartup = false
    private var didScheduleInitialMainWindowBootstrap = false
    var shouldDeferInitialMainWindowBootstrapForExternalConfirmation = false
    private var didBootstrapInitialMainWindow = false
    var isTerminatingApp = false
    private var closedWindowHistorySuppressedWindowIds: Set<UUID> = []
#if DEBUG
    var closeMainWindowContainingTabIdObserverForTesting: ((UUID, Bool) -> Void)?
#endif
    // Avoid showing the quit warning twice after confirmation.
    private var isQuitWarningConfirmed = false
    // One-shot guard for deferred terminate replies.
    private var didReplyToTerminate = false
    // True while remote tmux kill-before-quit owns the terminate reply.
    private var isAwaitingTerminateKills = false
    private var terminateKillWatchdogTask: Task<Void, Never>?
    /// Force-exits if AppKit's terminate gauntlet wedges (#6758).
    private let terminationWatchdog = TerminationWatchdog()
    private var activeQuitConfirmationAlertPresenter: QuitConfirmationAlertPresenter?
    private var activeQuitConfirmationOwnsTerminateRequest = false
    private var didInstallLifecycleSnapshotObservers = false
    static let screenChangeReconcileNotification = Notification.Name("com.cmuxterm.app.screenChangeReconcile")
    static let displayReconfigurationNotification = Notification.Name("com.cmuxterm.app.displayReconfiguration")
    static let screenChangeReconcileRetryLimit = 3
    var windowConfigFrames: [UUID: SessionConfigFrameRing] = [:]
    var lastAppliedConfigurationSignature: String?
    var didObserveUnknownDisplayConfiguration = false
    var screenChangeReconcileRetryBudget = 0
    var isScreenChangeCaptureSuppressed = false
    var screenChangeCaptureSuppressionSignature: String?
    var screenChangeCaptureSuppressionSignatureGeneration: Int?
    var displayReconfigurationGeneration = 0
    var didRegisterDisplayReconfigurationCallback = false
    private var didDisableSuddenTermination = false
    /// Owns the per-window command-palette state.
    let commandPaletteWindowStore = CommandPaletteWindowStore()
    private static let sessionAutosaveTypingQuietPeriod: TimeInterval = 0.65

    var updateViewModel: UpdateStateModel {
        updateController.model
    }

#if DEBUG
    private func pointerString(_ object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return String(describing: Unmanaged.passUnretained(object).toOpaque())
    }

    private func summarizeContextForWorkspaceRouting(_ context: MainWindowContext?) -> String {
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
        guard !mainWindowContexts.isEmpty else { return "<none>" }
        return mainWindowContexts.values
            .map { summarizeContextForWorkspaceRouting($0) }
            .joined(separator: " | ")
    }

    private func logWorkspaceCreationRouting(
        phase: String,
        source: String,
        reason: String,
        event: NSEvent?,
        chosenContext: MainWindowContext?,
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
        super.init()
        Self.shared = self
        // Inverts the surface registry's legacy AppDelegate.shared reach-up:
        // the registry asks this delegate (via MainWindowRouteRetiring) to
        // sweep recoverable main-window routes after a surface unregisters.
        GhosttyApp.terminalSurfaceRegistry.attachRouteRetirer(self)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        #if DEBUG
        AuthDebugLog().log("auth.openURLs.received count=\(urls.count) summaries=\(urls.map(Self.authURLDebugSummary).joined(separator: "|"))")
        #endif
        if handleCmuxExternalURLs(from: urls) {
            #if DEBUG
            AuthDebugLog().log("auth.openURLs.handledByExternalRoutes count=\(urls.count)")
            #endif
            return
        }

        // Before the auth graph is configured, fall back to a default router
        // (built-in cmux schemes) so dropped callbacks are still detected.
        let callbackRouter = auth?.callbackRouter ?? AuthCallbackRouter()
        let authCallbacks = urls.filter(callbackRouter.isAuthCallbackURL)
        #if DEBUG
        AuthDebugLog().log("auth.openURLs.authCallbacks count=\(authCallbacks.count)")
        #endif
        if let browserSignIn = auth?.browserSignIn {
            for url in authCallbacks {
                Task { @MainActor in
                    let signedIn = await browserSignIn.handleCallbackURL(url)
                    if !signedIn {
                        AuthDebugLog().log("auth.callback did not complete sign-in")
                    }
                }
            }
        } else if !authCallbacks.isEmpty {
            AuthDebugLog().log("auth.callback dropped: auth graph not configured yet")
        }

        let externalFileURLs = externalOpenFileURLs(from: urls)
        let terminalFileRequests = TerminalDefaultFileOpenRequest.requests(from: externalFileURLs)
        let terminalFilePaths = Set(terminalFileRequests.map { $0.fileURL.path(percentEncoded: false) })
        let fileURLs = externalFileURLs.filter { url in
            !terminalFilePaths.contains(url.standardizedFileURL.path(percentEncoded: false))
        }
        let directories = externalOpenDirectories(from: urls.filter { externalOpenURLIsDirectory($0) })
        guard !terminalFileRequests.isEmpty || !fileURLs.isEmpty || !directories.isEmpty else { return }

        prepareForExplicitOpenIntentAtStartup()
        for request in terminalFileRequests {
            openTerminalDefaultFileRequest(
                request,
                debugSource: "application.openURLs.defaultTerminal"
            )
        }
        for fileURL in fileURLs {
            _ = openFilePreviewInPreferredMainWindow(
                filePath: fileURL.path(percentEncoded: false),
                debugSource: "application.openURLs"
            )
        }
        for directory in directories {
            openWorkspaceForExternalDirectory(
                workingDirectory: directory,
                debugSource: "application.openURLs"
            )
        }
    }

    #if DEBUG
    private static func authURLDebugSummary(_ url: URL) -> String {
        let scheme = url.scheme ?? "nil"
        let target = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).joined(separator: ",") ?? ""
        return "\(scheme):\(target.isEmpty ? "nil" : target):\(queryItems.isEmpty ? "none" : queryItems)"
    }
    #endif

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
        let telemetryEnabled = TelemetrySettings.enabledForCurrentLaunch
        StartupBreadcrumbLog.append(
            "appDelegate.didFinish.begin",
            fields: [
                "xctest": isRunningUnderXCTest ? "1" : "0",
                "telemetry": telemetryEnabled ? "1" : "0"
            ]
        )
        AppIconLaunchState.markDidFinishLaunching()
        AppearanceSettingsUserDefaultsObserver.shared.startObserving()
        // Keep app chrome following live OS appearance switches (Shortcuts/scheduled
        // Auto) while in system mode; safe here, past the App.init() effectiveAppearance
        // crash window (#6385).
        SystemAppearanceObserver.shared.startObserving()
        BrowserSystemProxyWatcher.shared.startObserving()
        if isRunningUnderXCTest {
            NSApp.setActivationPolicy(.regular)
        } else {
            MenuBarOnlySettings.normalizeLegacyStoredPreference()
            syncActivationPolicy()
        }
        StartupBreadcrumbLog.append("appDelegate.didFinish.activationPolicy.synced")

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
                persistence: WorkstreamPersistence(fileURL: WorkstreamPersistence.defaultFileURL()),
                titleProvider: Self.feedWorkstreamTitle(for:)
            )
        )
        StartupBreadcrumbLog.append("appDelegate.didFinish.feedStore.installed")
        Task { @MainActor in
            await FeedCoordinator.shared.store?.start()
#if DEBUG
            setupFeedSidebarUITestIfNeeded()
#endif
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleThemesReloadNotification(_:)),
            name: CmuxThemeNotifications.reloadConfig,
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
        writeUITestDiagnosticsIfNeeded(stage: "didFinishLaunching")
        CmuxMainRunLoopStallMonitor.shared.installIfNeeded()
        CmuxMainThreadTurnProfiler.shared.installIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeUITestDiagnosticsIfNeeded(stage: "after1s")
        }
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
        if !isRunningUnderXCTest {
            CmuxFeatureFlags.shared.start()
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
            installMenuBarVisibilityObserver()
            syncApplicationPresentationPreferences()
            updateController.actionDelegate = self
            updateController.startUpdaterIfNeeded()
        }
        titlebarAccessoryController.start()
        windowDecorationsController.start()
        installMainWindowKeyObserver()
        refreshGhosttyGotoSplitShortcuts()
        installGhosttyConfigObserver()
        installGlobalFontMagnificationObserver()
        installWindowResponderSwizzles()
        installBrowserAddressBarFocusObservers()
        installShortcutMonitor()
        installShortcutDefaultsObserver()
        if !isRunningUnderXCTest {
            GlobalSearchCoordinator.shared.start()
            sentryStartMemoryContextRefresh()
        }
        SystemWideHotkeyController.shared.start()
        AgentHibernationController.shared.start()
        RendererRealizationController.shared.start()
        NSApp.servicesProvider = self

        StartupBreadcrumbLog.append("appDelegate.didFinish.bootstrap.begin")
        scheduleInitialMainWindowBootstrap(debugSource: "didFinishLaunching")
        StartupBreadcrumbLog.append("appDelegate.didFinish.complete")
#if DEBUG
        UpdateTestSupport(model: updateController.model, log: updateLog).applyIfNeeded()
        if env["CMUX_UI_TEST_MODE"] == "1" {
            let trigger = env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] ?? "<nil>"
            let feed = env["CMUX_UI_TEST_FEED_URL"] ?? "<nil>"
            updateLog.append("ui test env: trigger=\(trigger) feed=\(feed)")
        }
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" {
            updateLog.append("ui test trigger update check detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                let windowIds = NSApp.windows.map { $0.identifier?.rawValue ?? "<nil>" }
                updateLog.append("ui test windows: count=\(NSApp.windows.count) ids=\(windowIds.joined(separator: ","))")
                if UpdateTestSupport(model: self.updateController.model, log: updateLog).performMockFeedCheckIfNeeded() {
                    return
                }
                self.checkForUpdates(nil)
            }
        }

        // In UI tests, `WindowGroup` occasionally fails to materialize a window quickly on the VM.
        // If there are no windows shortly after launch, force-create one so XCUITest can proceed.
        if isRunningUnderXCTest {
            if let rawVariant = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_VARIANT"] {
                UserDefaults.standard.set(
                    BrowserImportHintSettings.variant(for: rawVariant).rawValue,
                    forKey: BrowserImportHintSettings.variantKey
                )
            }
            if let rawShow = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_SHOW"] {
                UserDefaults.standard.set(
                    rawShow == "1",
                    forKey: BrowserImportHintSettings.showOnBlankTabsKey
                )
            }
            if let rawDismissed = env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_DISMISSED"] {
                UserDefaults.standard.set(
                    rawDismissed == "1",
                    forKey: BrowserImportHintSettings.dismissedKey
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if NSApp.windows.isEmpty {
                    self.openNewMainWindow(nil)
                }
                self.moveUITestWindowToTargetDisplayIfNeeded()
                NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                // On headless CI runners, activate() silently fails (no GUI session).
                // Force windows visible so the terminal surface starts rendering.
                for window in NSApp.windows {
                    window.orderFrontRegardless()
                }
                self.writeUITestDiagnosticsIfNeeded(stage: "afterForceWindow")
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_BLANK_BROWSER"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self else { return }
                    _ = self.openBrowserAndFocusAddressBar(insertAtEnd: true)
                }
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_HINT_OPEN_SETTINGS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                    self?.openPreferencesWindow(
                        debugSource: "uiTest.browserImportHint",
                        navigationTarget: .browser
                    )
                }
            }
            if env["CMUX_UI_TEST_BROWSER_IMPORT_AUTO_OPEN"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    BrowserDataImportCoordinator.shared.presentImportDialog()
                }
            }
        }
#endif
    }

    private nonisolated static func feedWorkstreamTitle(for event: WorkstreamEvent) -> String? {
        switch event.hookEventName {
        case .preCompact, .postCompact:
            return String(localized: "feed.lifecycle.compaction.title", defaultValue: "Compaction")
        case .subagentStart, .subagentStop:
            return String(localized: "feed.lifecycle.subagent.title", defaultValue: "Subagent")
        default:
            return nil
        }
    }

#if DEBUG
    private func writeUITestDiagnosticsIfNeeded(stage: String) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_DIAGNOSTICS_PATH"], !path.isEmpty else { return }

        var payload = loadUITestDiagnostics(at: path)
        let isRunningUnderXCTest = isRunningUnderXCTest(env)

        let windows = NSApp.windows
        let ids = windows.map { $0.identifier?.rawValue ?? "" }.joined(separator: ",")
        let vis = windows.map { $0.isVisible ? "1" : "0" }.joined(separator: ",")
        let screenIDs = windows.map { $0.screen?.cmuxDisplayID.map(String.init) ?? "" }.joined(separator: ",")
        let targetDisplayID = env["CMUX_UI_TEST_TARGET_DISPLAY_ID"] ?? ""

        payload["stage"] = stage
        payload["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        payload["bundleId"] = Bundle.main.bundleIdentifier ?? ""
        payload["isRunningUnderXCTest"] = isRunningUnderXCTest ? "1" : "0"
        payload["windowsCount"] = String(windows.count)
        payload["windowIdentifiers"] = ids
        payload["windowVisibleFlags"] = vis
        payload["windowScreenDisplayIDs"] = screenIDs
        payload["uiTestTargetDisplayID"] = targetDisplayID
        if let rawDisplayID = UInt32(targetDisplayID) {
            let screenPresent = NSScreen.screens.contains(where: { $0.cmuxDisplayID == rawDisplayID })
            let movedWindow = windows.contains(where: { $0.screen?.cmuxDisplayID == rawDisplayID })
            payload["targetDisplayPresent"] = screenPresent ? "1" : "0"
            payload["targetDisplayMoveSucceeded"] = movedWindow ? "1" : "0"
        }
        appendUITestRenderDiagnosticsIfNeeded(&payload, environment: env)
        appendUITestSocketDiagnosticsIfNeeded(&payload, environment: env)
        appendUITestPortalDiagnosticsIfNeeded(&payload, environment: env)

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadUITestDiagnostics(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func appendUITestSocketDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        guard let config = socketListenerConfigurationIfEnabled() else {
            payload["socketExpectedPath"] = env["CMUX_SOCKET_PATH"] ?? ""
            payload["socketMode"] = "off"
            payload["socketReady"] = "0"
            payload["socketPingResponse"] = ""
            payload["socketIsRunning"] = "0"
            payload["socketAcceptLoopAlive"] = "0"
            payload["socketPathMatches"] = "0"
            payload["socketPathExists"] = "0"
            payload["socketPathOwnedByListener"] = "0"
            payload["socketFailureSignals"] = "socket_disabled"
            return
        }

        let socketPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
        let pingResponse = health.isHealthy
            ? socketTransport.probeCommand("ping", at: socketPath, timeout: 1.0)
            : nil
        let isReady = health.isHealthy && pingResponse == "PONG"
        var failureSignals = health.failureSignals
        if health.isHealthy && pingResponse != "PONG" {
            failureSignals.append("ping_timeout")
        }

        payload["socketExpectedPath"] = socketPath
        payload["socketMode"] = config.mode.rawValue
        payload["socketReady"] = isReady ? "1" : "0"
        payload["socketPingResponse"] = pingResponse ?? ""
        payload["socketIsRunning"] = health.isRunning ? "1" : "0"
        payload["socketAcceptLoopAlive"] = health.acceptLoopAlive ? "1" : "0"
        payload["socketPathMatches"] = health.socketPathMatches ? "1" : "0"
        payload["socketPathExists"] = health.socketPathExists ? "1" : "0"
        payload["socketPathOwnedByListener"] = health.socketPathOwnedByListener ? "1" : "0"
        payload["socketFailureSignals"] = failureSignals.joined(separator: ",")
    }

    private func appendUITestPortalDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_PORTAL_STATS"] == "1" else { return }

        let stats = TerminalWindowPortalRegistry.debugPortalStats()
        payload["portal_count"] = Self.uiTestStringValue(stats["portal_count"])
        payload["portal_hosted_mapping_count"] = Self.uiTestStringValue(stats["hosted_mapping_count"])
        payload["portal_guarded_bind_blocked_count"] = Self.uiTestStringValue(stats["guarded_bind_blocked_count"])
        if let totals = stats["totals"] as? [String: Any] {
            for (key, value) in totals {
                payload["portal_\(key)"] = Self.uiTestStringValue(value)
            }
        }
    }

    private static func uiTestStringValue(_ value: Any?) -> String {
        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value ? "1" : "0"
        case let value as Int:
            return String(value)
        case let value as NSNumber:
            return value.stringValue
        case let value as UUID:
            return value.uuidString
        case .some(let value):
            return String(describing: value)
        case .none:
            return ""
        }
    }

    private func appendUITestRenderDiagnosticsIfNeeded(
        _ payload: inout [String: String],
        environment env: [String: String]
    ) {
        guard env["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }

        guard let renderState = currentUITestRenderDiagnostics() else {
            payload["renderStatsAvailable"] = "0"
            payload["renderPanelId"] = ""
            payload["renderDrawCount"] = ""
            payload["renderPresentCount"] = ""
            payload["renderLastPresentTime"] = ""
            payload["renderWindowVisible"] = ""
            payload["renderAppIsActive"] = ""
            payload["renderDesiredFocus"] = ""
            payload["renderIsFirstResponder"] = ""
            payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
            return
        }

        payload["renderStatsAvailable"] = "1"
        payload["renderPanelId"] = renderState.panelId.uuidString
        payload["renderDrawCount"] = String(renderState.drawCount)
        payload["renderPresentCount"] = String(renderState.presentCount)
        payload["renderLastPresentTime"] = String(format: "%.6f", renderState.lastPresentTime)
        payload["renderWindowVisible"] = renderState.windowVisible ? "1" : "0"
        payload["renderAppIsActive"] = renderState.appIsActive ? "1" : "0"
        payload["renderDesiredFocus"] = renderState.desiredFocus ? "1" : "0"
        payload["renderIsFirstResponder"] = renderState.isFirstResponder ? "1" : "0"
        payload["renderDiagnosticsUpdatedAt"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
    }

    private func currentUITestRenderDiagnostics() -> UITestRenderDiagnosticsSnapshot? {
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
        return UITestRenderDiagnosticsSnapshot(
            panelId: terminalPanel.id,
            drawCount: stats.drawCount,
            presentCount: stats.presentCount,
            lastPresentTime: stats.lastPresentTime,
            windowVisible: stats.windowOcclusionVisible,
            appIsActive: stats.appIsActive,
            desiredFocus: stats.desiredFocus,
            isFirstResponder: stats.isFirstResponder
        )
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
#endif

    func applicationWillBecomeActive(_ notification: Notification) { if !hasVisibleMainTerminalWindow() { _ = mainWindowVisibilityController.orderFrontApplicationWindowsBeforeActivation(windows: mainWindowsForVisibilityController(), reason: .applicationWillBecomeActive) } }

    func applicationDidBecomeActive(_ notification: Notification) {
        PortScanner.shared.setTrackedAgentScanningPaused(false)
        let activationWindows = mainWindowsForVisibilityController()
        if mainWindowVisibilityController.finishPendingApplicationActivationRestore(windows: activationWindows, reason: .applicationDidBecomeActive) == nil, !hasVisibleMainTerminalWindow() {
            _ = mainWindowVisibilityController.restoreApplicationWindowsAfterActivation(windows: activationWindows, reason: .applicationDidBecomeActive)
        }
        sentryBreadcrumb("app.didBecomeActive", category: "lifecycle", data: [
            "tabCount": tabManager?.tabs.count ?? 0
        ])
        if TelemetrySettings.enabledForCurrentLaunch && !isRunningUnderXCTestCached {
            PostHogAnalytics.shared.trackActive(reason: "didBecomeActive")
        }

        guard let notificationStore else { return }
        notificationStore.handleApplicationDidBecomeActive()
        guard let tabManager else { return }
        guard let tabId = tabManager.selectedTabId else { return }
        let surfaceId = tabManager.focusedSurfaceId(for: tabId)
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }

        if let surfaceId,
           let tab = tabManager.tabs.first(where: { $0.id == tabId }),
           notificationStore.hasUnreadNotificationRequiringPaneFlash(forTabId: tabId, surfaceId: surfaceId) {
            tab.triggerNotificationFocusFlash(panelId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    /// Sole caller of `NSApp.reply(toApplicationShouldTerminate:)`.
    private func replyToTerminateOnce(_ shouldTerminate: Bool) {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
        terminateKillWatchdogTask?.cancel()
        terminateKillWatchdogTask = nil
        // A cancelled quit ends this terminate request; the next quit must reply again.
        if !shouldTerminate {
            didReplyToTerminate = false
            isAwaitingTerminateKills = false
        }
    }

    private func deferTerminateForMarkedRemoteTmuxKills(reason: String) -> Bool {
        let markedForKill = remoteTmuxController.windowsMarkedForKillOnClose()
        guard !markedForKill.isEmpty else { return false }
        if !isAwaitingTerminateKills {
            isAwaitingTerminateKills = true
            StartupBreadcrumbLog.append("appDelegate.shouldTerminate.killLater", fields: ["windows": String(markedForKill.count), "reason": reason])
            Task { @MainActor in
                await self.remoteTmuxController.killMarkedSessionsBeforeTerminate()
                self.replyToTerminateOnce(true)
            }
            // Watchdog: release quit if the deferred Task is starved inside a nested run loop.
            terminateKillWatchdogTask?.cancel()
            terminateKillWatchdogTask = Task { @MainActor [weak self] in
                try? await ContinuousClock().sleep(for: .milliseconds(3_500))
                guard !Task.isCancelled else { return }
                self?.replyToTerminateOnce(true)
            }
        }
        return true
    }

    private func clearMarkedRemoteTmuxKills() {
        for windowId in remoteTmuxController.windowsMarkedForKillOnClose() {
            remoteTmuxController.consumeKillSessionsOnWindowClose(windowId: windowId)
        }
    }

    private func prepareForConfirmedAppTermination() {
        isTerminatingApp = true
        _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
        ClosedItemHistoryStore.shared.flushPendingSaves()
        // Quit is committed and the critical state is now on disk. Bound the
        // remainder of the terminate sequence so a blocked Apple will-terminate
        // observer (e.g. CFPasteboardResolveAllPromisedData, #6758) can't hang
        // the main thread for ~30s. Idempotent and a no-op if the process exits
        // first.
        terminationWatchdog.arm()
    }

    private func presentQuitConfirmationAlert(
        ownsTerminateRequest: Bool,
        completion: @escaping QuitConfirmationAlertPresenter.Completion
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

    private func handleApplicationTerminateQuitConfirmationResponse(
        _ response: NSApplication.ModalResponse,
        suppressionState: NSControl.StateValue
    ) {
        if suppressionState == .on {
            QuitConfirmationStore(defaults: .standard).setEnabled(false)
        }

        let shouldQuit = response == .alertFirstButtonReturn
        if shouldQuit {
            prepareForConfirmedAppTermination()
            isQuitWarningConfirmed = true
            closeAllWebInspectorsBeforeAppTeardown()
            StartupBreadcrumbLog.append("appDelegate.shouldTerminate.reply", fields: ["shouldQuit": "1"])
            if deferTerminateForMarkedRemoteTmuxKills(reason: "confirmedDialog") {
                return
            }
        } else {
            // Reset so that the next quit attempt can show the dialog again.
            isTerminatingApp = false
            clearMarkedRemoteTmuxKills()
            StartupBreadcrumbLog.append("appDelegate.shouldTerminate.reply", fields: ["shouldQuit": "0"])
        }
        replyToTerminateOnce(shouldQuit)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let reply = Self.pendingTerminateReply(
            isAwaitingTerminateKills: isAwaitingTerminateKills,
            hasActiveQuitConfirmation: activeQuitConfirmationAlertPresenter != nil,
            activeQuitConfirmationOwnsTerminateRequest: activeQuitConfirmationOwnsTerminateRequest
        ) {
            return reply
        }
        let buildFlavor = BuildFlavor.current
        let quitConfirmationStore = QuitConfirmationStore(defaults: .standard)
        let hasDirtyWorkspaces = hasQuitConfirmationDirtyWorkspaces()
        let confirmQuitMode = quitConfirmationStore.confirmQuitMode

        StartupBreadcrumbLog.append(
            "appDelegate.shouldTerminate.begin",
            fields: [
                "buildFlavor": buildFlavor.rawValue,
                "confirmQuitMode": confirmQuitMode.rawValue,
                "hasDirtyWorkspaces": hasDirtyWorkspaces ? "1" : "0",
                "quitWarningConfirmed": isQuitWarningConfirmed ? "1" : "0",
                "quitWarningEnabled": quitConfirmationStore.isEnabled ? "1" : "0"
            ]
        )

        // If the user already confirmed via the Cmd+Q shortcut warning dialog,
        // or policy skips the warning, avoid a second alert.
        if !quitConfirmationStore.shouldShowConfirmation(
            isQuitWarningConfirmed: isQuitWarningConfirmed,
            hasDirtyWorkspaces: hasDirtyWorkspaces,
            isDevBuild: buildFlavor == .dev
        ) {
            prepareForConfirmedAppTermination()
            closeAllWebInspectorsBeforeAppTeardown()
            let reason: String
            if isQuitWarningConfirmed {
                reason = "confirmed"
            } else if buildFlavor == .dev {
                reason = "devBuild"
            } else {
                reason = "policy"
            }
            // Explicit last-tab closes kill marked remote sessions before quit.
            // Plain app/window quits have no marker and only detach.
            if deferTerminateForMarkedRemoteTmuxKills(reason: reason) {
                return .terminateLater
            }
            StartupBreadcrumbLog.append("appDelegate.shouldTerminate.terminateNow", fields: ["reason": reason])
            return .terminateNow
        }

        // Show the same confirmation dialog used by the Cmd+Q shortcut path,
        // then reply asynchronously so we can return .terminateLater now.
        presentQuitConfirmationAlert(ownsTerminateRequest: true) { [weak self] response, suppressionState in
            self?.handleApplicationTerminateQuitConfirmationResponse(
                response,
                suppressionState: suppressionState
            )
        }
        StartupBreadcrumbLog.append("appDelegate.shouldTerminate.later")
        return .terminateLater
    }

    @discardableResult
    private func closeAllWebInspectorsBeforeAppTeardown() -> Int {
        WebViewInspectorTeardown.closeAllInspectors(in: NSApp.windows)
    }

    func applicationWillTerminate(_ notification: Notification) {
        StartupBreadcrumbLog.append("appDelegate.willTerminate.begin")
        // Backstop for any terminate path that did not route through
        // prepareForConfirmedAppTermination() (idempotent with the primary arm).
        // Apple's promised-pasteboard observer can fire before this delegate
        // method, so the primary arm above is what bounds #6758; this only
        // widens coverage to other entrypoints.
        isTerminatingApp = true
        _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
        ClosedItemHistoryStore.shared.flushPendingSaves()
        terminationWatchdog.arm()
        sentryStopMemoryContextRefresh()
        // Plain quit detaches local ssh clients; explicit close already killed marked sessions.
        remoteTmuxController.detachAll()
        // Best-effort presence goodbye; unclean exits are covered by the
        // service's missed-heartbeat timeout.
        PresenceHeartbeatClient.shared.appWillTerminate()
        closeAllWebInspectorsBeforeAppTeardown()
        stopSessionAutosaveTimer()
        CloudVMActionLauncher.shared.terminateAll()
        CmuxSSHURLProcessLauncher.shared.terminateAll()
        MobileHostService.shared.stop()
        TerminalController.shared.stop()
        GhosttyApp.terminalPasteboard.cleanupAllOwnedTemporaryImageFiles()
        VSCodeServeWebController.shared.stop()
        BrowserProfileStore.shared.flushPendingSaves()
        ghosttyCrashBreadcrumbTask?.cancel()
        ghosttyCrashBreadcrumbTask = nil
        notificationStore?.clearAll()
        GhosttyCrashBreadcrumb.markCleanExit()
        unregisterDisplayReconfigurationCallbackIfNeeded()
        StartupBreadcrumbLog.append("appDelegate.willTerminate.complete")
        enableSuddenTerminationIfNeeded()
    }

    func applicationWillResignActive(_ notification: Notification) {
        guard !isTerminatingApp else { return }
        PortScanner.shared.setTrackedAgentScanningPaused(true)
        clearConfiguredShortcutChordState()
        if Self.shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp: isTerminatingApp) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
        }
    }

    func persistSessionForUpdateRelaunch() {
        isTerminatingApp = true
        _ = saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
        ClosedItemHistoryStore.shared.flushPendingSaves()
    }

    func configure(
        tabManager: TabManager,
        notificationStore: TerminalNotificationStore,
        sidebarState: SidebarState,
        settingsRuntime: SettingsRuntime,
        auth: MacAuthComposition
    ) {
        self.tabManager = tabManager
        self.settingsRuntime = settingsRuntime
        self.notificationStore = notificationStore
        self.sidebarState = sidebarState
        self.auth = auth
        VMClient.bootstrap(auth: auth.coordinator)
        RemotesClient.bootstrap(auth: auth.coordinator)
        AIAccountsClient.bootstrap(auth: auth.coordinator)
        PhonePushClient.shared.configure(auth: auth.coordinator)
        MobileHostService.shared.configure(auth: auth.coordinator)
        DeviceRegistryClient.shared.configure(auth: auth.coordinator)
        PresenceHeartbeatClient.shared.configure(auth: auth.coordinator)
        // DEV-only: auto-publish this Mac's attach route to the signed-in user's
        // pairedMacs backup so a fresh dev iOS build restores it (no manual host
        // entry). No-op on Release / when the flag is off.
        MacPairedMacBackupPublisher.shared.configure(auth: auth.coordinator)
        TerminalController.shared.attachAuth(coordinator: auth.coordinator, browserSignIn: auth.browserSignIn)
        TerminalController.shared.agentChatTranscriptService = agentChatTranscriptService
        auth.start()
        ensureMobileWorkspaceListObserver(for: tabManager)
        MobileTerminalRenderObserver.shared.start()
        agentChatTranscriptService.start()
        installMobileHostSettingsObserver()
        scheduleGhosttyCrashBreadcrumbIfNeeded(notificationStore: notificationStore)
        startPaneMemoryGuardrailIfNeeded()
        disableSuddenTerminationIfNeeded()
        installLifecycleSnapshotObserversIfNeeded()
        // Seed so the first display change after launch can restore geometry.
        lastAppliedConfigurationSignature = currentDisplayConfigurationSignature()
        prepareStartupSessionSnapshotIfNeeded()
        startSessionAutosaveTimerIfNeeded()
#if DEBUG
        setupJumpUnreadUITestIfNeeded()
        setupTerminalCmdClickUITestIfNeeded()
        setupGotoSplitUITestIfNeeded()
        setupBonsplitTabDragUITestIfNeeded()
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
    private func setupTerminalCmdClickUITestIfNeeded() {
        guard !didSetupTerminalCmdClickUITest else { return }

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP"] == "1" else {
            cmuxDebugLog("cmdclick.ui.setup skip reason=env_missing tag=\(env["CMUX_TAG"] ?? "nil")")
            return
        }
        guard let manifestPath = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !manifestPath.isEmpty else {
            cmuxDebugLog("cmdclick.ui.setup skip reason=missing_manifest_path")
            return
        }
        didSetupTerminalCmdClickUITest = true
        guard let fixtureDirectory = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !fixtureDirectory.isEmpty else {
            cmuxDebugLog("cmdclick.ui.setup error reason=missing_fixture_dir manifest=\(manifestPath)")
            writeTerminalCmdClickUITestData(at: manifestPath, updates: [
                "setupError": "Missing fixture directory"
            ])
            return
        }
        let commandPath = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let screenshotDirectory = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SCREENSHOT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayMode = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lineFormat = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let linePrefix = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_PREFIX"] ?? ""
        let displaySuffix = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_SUFFIX"] ?? ""
        let displayAsAbsolutePath = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_AS_ABSOLUTE_PATH"] == "1"
        if let rawOpenSupportedFiles = env["CMUX_UI_TEST_OPEN_SUPPORTED_FILES_IN_CMUX"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawOpenSupportedFiles.isEmpty {
            FileRouteSettingsStore(defaults: .standard).setSupportedFileRouteEnabled(rawOpenSupportedFiles == "1")
        }
        if let rawOpenMarkdown = env["CMUX_UI_TEST_OPEN_MARKDOWN_IN_CMUX_VIEWER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawOpenMarkdown.isEmpty {
            FileRouteSettingsStore(defaults: .standard).setMarkdownRouteEnabled(rawOpenMarkdown == "1")
        }
        let extraFileNamesJSON = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_EXTRA_FILE_NAMES_JSON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let fileName = env["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFileName = (fileName?.isEmpty == false) ? fileName! : "Cmd Click Fixture.txt"
        let fixtureDirectoryURL = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
        let expectedFileURL = fixtureDirectoryURL.appendingPathComponent(resolvedFileName)
        let siblingFileURL = fixtureDirectoryURL.appendingPathComponent("OtherFile")
        let extraFileNames: [String]
        if let extraFileNamesJSON,
           let data = extraFileNamesJSON.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String] {
            extraFileNames = values
        } else {
            extraFileNames = []
        }
        let escapedToken = resolvedFileName.replacingOccurrences(of: " ", with: "\\ ")
        let baseDisplayToken = displayAsAbsolutePath ? expectedFileURL.path : resolvedFileName
        let resolvedDisplayMode = (displayMode == "raw") ? "raw" : "escaped"
        let resolvedLineFormat: String
        switch lineFormat {
        case "log":
            resolvedLineFormat = "log"
        case "alt_screen_log":
            resolvedLineFormat = "alt_screen_log"
        case "osc8":
            resolvedLineFormat = "osc8"
        default:
            resolvedLineFormat = "grid"
        }
        cmuxDebugLog(
            "cmdclick.ui.setup start manifest=\(manifestPath) fixture=\(fixtureDirectory) " +
                "command=\(commandPath ?? "nil") display=\(resolvedDisplayMode) " +
                "lineFormat=\(resolvedLineFormat) " +
                "file=\(resolvedFileName)"
        )
        func singleQuotedShellLiteral(_ text: String) -> String {
            text.replacingOccurrences(of: "'", with: "'\"'\"'")
        }
        let displayToken: String
        let shellCommand: String
        switch resolvedLineFormat {
        case "osc8":
            displayToken = resolvedFileName
            let escapedDisplayToken = singleQuotedShellLiteral(displayToken)
            let escapedURL = singleQuotedShellLiteral(expectedFileURL.absoluteString)
            shellCommand = "clear\rfor i in $(seq 1 48); do printf '\\033]8;;%s\\033\\\\%s\\033]8;;\\033\\\\\\n' '\(escapedURL)' '\(escapedDisplayToken)'; done\r"
        case "log":
            displayToken = "\(baseDisplayToken)\(displaySuffix)"
            let blockLine = "\(linePrefix)\(displayToken)"
            let shellBlockLine = singleQuotedShellLiteral(blockLine)
            shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
        case "alt_screen_log":
            displayToken = "\(baseDisplayToken)\(displaySuffix)"
            let blockLine = "\(linePrefix)\(displayToken)"
            let shellBlockLine = singleQuotedShellLiteral(blockLine)
            shellCommand = "clear\rprintf '\\033[?1049h\\033[H\\033[2J'; for i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
        default:
            switch resolvedDisplayMode {
            case "raw":
                displayToken = "\(baseDisplayToken)\(displaySuffix)"
                let blockLine = "\(displayToken)    OtherFile"
                let shellBlockLine = singleQuotedShellLiteral(blockLine)
                shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
            default:
                displayToken = "\(escapedToken)\(displaySuffix)"
                let blockLine = Array(repeating: displayToken, count: 3).joined(separator: " ")
                let shellBlockLine = singleQuotedShellLiteral(blockLine)
                shellCommand = "clear\rfor i in $(seq 1 48); do printf '%s\\n' '\(shellBlockLine)'; done\r"
            }
        }
        let deadline = Date().addingTimeInterval((commandPath?.isEmpty == false) ? 60.0 : 20.0)
        var seeded = false
        var resolved = false
        var tokenPointPayload: [String: Any]?
        var observers: [NSObjectProtocol] = []
        var lastHandledCommandID: String?
        var screenshotSequence = 0

        func rectPayload(_ rect: CGRect) -> [String: Double] {
            [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height
            ]
        }

        func pointPayload(x: CGFloat, yFromTop: CGFloat) -> [String: Double] {
            [
                "x": x,
                "y": yFromTop
            ]
        }

        func doubleValue(_ value: Any?) -> Double? {
            if let value = value as? Double {
                return value
            }
            if let value = value as? NSNumber {
                return value.doubleValue
            }
            return nil
        }

        func pointFromPayload(_ key: String, in terminalPanel: TerminalPanel) -> NSPoint? {
            guard let payload = tokenPointPayload?[key] as? [String: Any],
                  let x = doubleValue(payload["x"]),
                  let yFromTop = doubleValue(payload["y"]) else {
                return nil
            }

            let clampedX = min(max(CGFloat(x), 1), max(terminalPanel.hostedView.bounds.width - 1, 1))
            let clampedYFromTop = min(
                max(CGFloat(yFromTop), 1),
                max(terminalPanel.hostedView.bounds.height - 1, 1)
            )
            return NSPoint(
                x: clampedX,
                y: terminalPanel.hostedView.bounds.height - clampedYFromTop
            )
        }

        func pointForTokenColumnOffset(_ offset: Int, in terminalPanel: TerminalPanel) -> NSPoint? {
            guard let selectionStart = pointFromPayload("tokenSelectionStartInTerminal", in: terminalPanel),
                  let tokenCellMetrics = tokenPointPayload?["tokenCellMetrics"] as? [String: Any],
                  let cellWidth = doubleValue(tokenCellMetrics["cellWidth"]) else {
                return nil
            }

            let unclampedX = selectionStart.x + (CGFloat(offset) * CGFloat(cellWidth))
            let clampedX = min(max(unclampedX, 1), max(terminalPanel.hostedView.bounds.width - 1, 1))
            return NSPoint(x: clampedX, y: selectionStart.y)
        }

        func commandPoint(
            from command: [String: Any],
            defaultPayloadKey: String,
            in terminalPanel: TerminalPanel
        ) -> NSPoint? {
            if let tokenColumnOffset = command["tokenColumnOffset"] as? Int {
                return pointForTokenColumnOffset(tokenColumnOffset, in: terminalPanel)
            }
            if let tokenColumnOffset = command["tokenColumnOffset"] as? NSNumber {
                return pointForTokenColumnOffset(tokenColumnOffset.intValue, in: terminalPanel)
            }
            return pointFromPayload(defaultPayloadKey, in: terminalPanel)
        }

        func loadCommand(at path: String) -> [String: Any]? {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }

        func tokenPoints(in terminalPanel: TerminalPanel, visibleText: String) -> [String: Any]? {
            guard let surface = terminalPanel.surface.surface else { return nil }
            let bounds = terminalPanel.hostedView.bounds
            guard bounds.width > 0, bounds.height > 0 else { return nil }

            let size = ghostty_surface_size(surface)
            let rows = max(Int(size.rows), 1)
            let cols = max(Int(size.columns), 1)
            let debugCellSize = terminalPanel.hostedView.debugCellSize
            let cellWidth = debugCellSize.width > 0 ? debugCellSize.width : CGFloat(size.cell_width_px)
            let cellHeight = debugCellSize.height > 0 ? debugCellSize.height : CGFloat(size.cell_height_px)
            guard cellWidth > 0, cellHeight > 0 else { return nil }

            let xInset = max(0, (bounds.width - (CGFloat(cols) * cellWidth)) / 2)
            let yInset = max(0, (bounds.height - (CGFloat(rows) * cellHeight)) / 2)
            let pointClampX: (CGFloat) -> CGFloat = { x in
                min(bounds.width - 4, max(4, x))
            }
            let pointClampY: (CGFloat) -> CGFloat = { y in
                min(bounds.height - 4, max(4, y))
            }

            let rawVisibleLines = visibleText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let visibleLines = rawVisibleLines.count > rows ? Array(rawVisibleLines.suffix(rows)) : rawVisibleLines
            let rowOffset = max(0, rows - visibleLines.count)

            var matchedRowFromTop: Int?
            var matchedColumnStart: Int?
            var matchedColumnEnd: Int?
            var matchedLine = ""
            var matchingLines: [(lineIndex: Int, line: String, ranges: [Range<String.Index>])] = []

            for (lineIndex, line) in visibleLines.enumerated() {
                var searchStart = line.startIndex
                var ranges: [Range<String.Index>] = []
                while searchStart < line.endIndex,
                      let range = line.range(of: displayToken, range: searchStart..<line.endIndex) {
                    ranges.append(range)
                    searchStart = range.upperBound
                }
                if !ranges.isEmpty {
                    matchingLines.append((lineIndex, line, ranges))
                }
            }

            if !matchingLines.isEmpty {
                let selectedLine = matchingLines[matchingLines.count / 2]
                let selectedRange = selectedLine.ranges[selectedLine.ranges.count / 2]
                let startColumn = selectedLine.line.distance(from: selectedLine.line.startIndex, to: selectedRange.lowerBound)
                let endColumnExclusive = selectedLine.line.distance(from: selectedLine.line.startIndex, to: selectedRange.upperBound)
                if startColumn < cols {
                    matchedRowFromTop = rowOffset + selectedLine.lineIndex
                    matchedColumnStart = startColumn
                    matchedColumnEnd = max(startColumn, endColumnExclusive - 1)
                    matchedLine = selectedLine.line
                }
            }

            guard let matchedRowFromTop,
                  let matchedColumnStart,
                  let matchedColumnEnd else {
                return [
                    "tokenLayoutMatch": "0",
                    "tokenCellMetrics": [
                        "cellWidth": cellWidth,
                        "cellHeight": cellHeight,
                        "columns": cols,
                        "rows": rows,
                        "xInset": xInset,
                        "yInset": yInset,
                        "visibleLineCount": visibleLines.count
                    ]
                ]
            }

            let yFromTop = pointClampY(yInset + (CGFloat(matchedRowFromTop) * cellHeight) + (cellHeight / 2))
            let startX = pointClampX(xInset + (CGFloat(matchedColumnStart) * cellWidth) + (cellWidth / 2))
            let endX = pointClampX(xInset + (CGFloat(matchedColumnEnd) * cellWidth) + (cellWidth / 2))
            let hitX = pointClampX(startX + min(cellWidth * 2, max(0, endX - startX)))
            return [
                "tokenHitPointInTerminal": pointPayload(x: hitX, yFromTop: yFromTop),
                "tokenSelectionStartInTerminal": pointPayload(x: startX, yFromTop: yFromTop),
                "tokenSelectionEndInTerminal": pointPayload(x: endX, yFromTop: yFromTop),
                "tokenQuicklookWord": displayToken,
                "tokenLayoutMatch": "1",
                "tokenCellMetrics": [
                    "cellWidth": cellWidth,
                    "cellHeight": cellHeight,
                    "columns": cols,
                    "rows": rows,
                    "xInset": xInset,
                    "yInset": yInset,
                    "visibleLineCount": visibleLines.count,
                    "matchedRowFromTop": matchedRowFromTop,
                    "matchedColumnStart": matchedColumnStart,
                    "matchedColumnEnd": matchedColumnEnd,
                    "matchedLine": matchedLine
                ]
            ]
        }

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            terminalCmdClickUITestPoller?.cancel()
            terminalCmdClickUITestPoller = nil
        }

        func writeState(
            terminalPanel: TerminalPanel?,
            window: NSWindow?,
            ready: Bool,
            setupError: String? = nil,
            additionalPayload: [String: Any] = [:]
        ) {
            var payload: [String: Any] = [
                "ready": ready ? "1" : "0",
                "escapedToken": escapedToken,
                "displayMode": resolvedDisplayMode,
                "lineFormat": resolvedLineFormat,
                "displayToken": displayToken,
                "fileName": resolvedFileName,
                "expectedPath": expectedFileURL.path,
                "fixtureDirectory": fixtureDirectoryURL.path
            ]
            if let terminalPanel {
                let terminalFrame = terminalPanel.hostedView.debugPortalFrameInWindow
                payload["surfaceId"] = terminalPanel.id.uuidString
                payload["terminalVisibleInUI"] = terminalPanel.hostedView.debugPortalVisibleInUI ? "1" : "0"
                payload["terminalFrameInWindow"] = rectPayload(terminalFrame)
            }
            if let window {
                payload["windowFrame"] = rectPayload(window.frame)
                payload["windowVisible"] = window.isVisible ? "1" : "0"
            }
            if let setupError {
                payload["setupError"] = setupError
            }
            if let tokenPointPayload {
                for (key, value) in tokenPointPayload {
                    payload[key] = value
                }
            }
            for (key, value) in additionalPayload {
                payload[key] = value
            }
            writeTerminalCmdClickUITestData(at: manifestPath, updates: payload)
        }

        func resizeWindowIfNeeded(_ window: NSWindow) {
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            guard let screenFrame else { return }
            let targetSize = NSSize(
                width: min(960, screenFrame.width - 80),
                height: min(720, screenFrame.height - 80)
            )
            let targetOrigin = NSPoint(
                x: screenFrame.minX + 40,
                y: screenFrame.maxY - 40 - targetSize.height
            )
            let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
            if !window.frame.equalTo(targetFrame) {
                window.setFrame(targetFrame, display: true)
            }
        }

        func safeScreenshotLabel(_ label: String) -> String {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            let scalars = label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
            let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
            return cleaned.isEmpty ? "capture" : cleaned
        }

        @MainActor
        func captureWindowSnapshotIfRequested(label: String, window: NSWindow) -> String? {
            guard let screenshotDirectory,
                  !screenshotDirectory.isEmpty,
                  let contentView = window.contentView else {
                return nil
            }
            let bounds = contentView.bounds
            guard !bounds.isEmpty,
                  let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                return nil
            }
            contentView.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }
            do {
                let directoryURL = URL(fileURLWithPath: screenshotDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let sequence = String(format: "%03d", screenshotSequence)
                screenshotSequence += 1
                let fileURL = directoryURL
                    .appendingPathComponent("\(sequence)-\(safeScreenshotLabel(label)).png")
                try data.write(to: fileURL, options: .atomic)
                return fileURL.path
            } catch {
                cmuxDebugLog("cmdclick.ui.snapshot failed label=\(label) error=\(error.localizedDescription)")
                return nil
            }
        }

        func cmdClickUITestTerminalPanel(in workspace: Workspace?) -> TerminalPanel? {
            guard let workspace else { return nil }
            if let focusedTerminalPanel = workspace.focusedTerminalPanel {
                return focusedTerminalPanel
            }
            return workspace.panels.values
                .compactMap { $0 as? TerminalPanel }
                .first { panel in
                    panel.surface.isViewInWindow &&
                        panel.hostedView.debugPortalVisibleInUI &&
                        !panel.hostedView.debugPortalFrameInWindow.isEmpty
                }
        }

        @MainActor
        func executePendingCommandIfNeeded(
            workspace: Workspace,
            terminalPanel: TerminalPanel,
            window: NSWindow
        ) {
            guard let commandPath,
                  !commandPath.isEmpty,
                  let command = loadCommand(at: commandPath),
                  let commandID = command["id"] as? String,
                  commandID != lastHandledCommandID else {
                return
            }

            let action = (command["action"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var payload: [String: Any] = [
                "lastCommandId": commandID,
                "lastCommandAction": action,
                "lastCommandSucceeded": "0"
            ]

            switch action {
            case "hover_token":
                guard let hitPoint = commandPoint(
                    from: command,
                    defaultPayloadKey: "tokenHitPointInTerminal",
                    in: terminalPanel
                ) else {
                    payload["lastCommandError"] = "Missing command point"
                    break
                }

                let result = terminalPanel.hostedView.debugSimulateCommandHoverDetails(at: hitPoint)
                payload["lastCommandResult"] = result
                payload["lastCommandHoverActive"] = result["hoverActive"]
                if let resolvedPath = result["resolvedPath"] as? String {
                    payload["lastCommandResolvedPath"] = resolvedPath
                    payload["lastCommandSucceeded"] = "1"
                } else if let error = result["error"] as? String {
                    payload["lastCommandError"] = error
                } else {
                    payload["lastCommandError"] = "Command hover did not resolve a path"
                }

            case "cmd_click_token":
                guard let hitPoint = commandPoint(
                    from: command,
                    defaultPayloadKey: "tokenHitPointInTerminal",
                    in: terminalPanel
                ) else {
                    payload["lastCommandError"] = "Missing command point"
                    break
                }

                let result = terminalPanel.hostedView.debugSimulateCommandClick(at: hitPoint)
                payload["lastCommandResult"] = result
                if let openedPath = result["openedPath"] as? String {
                    payload["lastCommandOpenedPath"] = openedPath
                    let canonicalOpenedPath = (openedPath as NSString).resolvingSymlinksInPath
                    let openedInFilePreview = workspace.panels.values.contains { panel in
                        guard let filePreview = panel as? FilePreviewPanel else { return false }
                        return (filePreview.filePath as NSString).resolvingSymlinksInPath == canonicalOpenedPath
                    }
                    let openedInMarkdownViewer = workspace.panels.values.contains { panel in
                        guard let markdown = panel as? MarkdownPanel else { return false }
                        return (markdown.filePath as NSString).resolvingSymlinksInPath == canonicalOpenedPath
                    }
                    payload["lastCommandOpenedInFilePreview"] = openedInFilePreview ? "1" : "0"
                    payload["lastCommandOpenedInMarkdownViewer"] = openedInMarkdownViewer ? "1" : "0"
                    payload["lastCommandSucceeded"] = "1"
                } else if let error = result["error"] as? String {
                    payload["lastCommandError"] = error
                } else {
                    payload["lastCommandError"] = "Command click did not open a path"
                }

            case "stationary_cmd_click_token":
                guard let hitPoint = commandPoint(
                    from: command,
                    defaultPayloadKey: "tokenHitPointInTerminal",
                    in: terminalPanel
                ) else {
                    payload["lastCommandError"] = "Missing command point"
                    break
                }

                let capturePath = ProcessInfo.processInfo.environment["CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH"]
                let beforeURLCount = capturePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
                    .split(separator: "\n").count ?? 0
                let result = terminalPanel.hostedView.debugSimulateStationaryCommandClick(at: hitPoint)
                payload["lastCommandResult"] = result
                let openedURLs = capturePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
                    .split(separator: "\n").map(String.init) ?? []
                if openedURLs.count > beforeURLCount, let openedURL = openedURLs.last {
                    payload["lastCommandOpenedURL"] = openedURL
                    payload["lastCommandSucceeded"] = "1"
                } else if let error = result["error"] as? String {
                    payload["lastCommandError"] = error
                } else {
                    payload["lastCommandError"] = "Stationary command click did not open a URL"
                }

            case "select_token_and_hold_command":
                guard let selectionStart = pointFromPayload("tokenSelectionStartInTerminal", in: terminalPanel),
                      let selectionEnd = pointFromPayload("tokenSelectionEndInTerminal", in: terminalPanel) else {
                    payload["lastCommandError"] = "Missing token selection points"
                    break
                }

                let selectionActive = terminalPanel.hostedView.debugSimulateSelection(
                    from: selectionStart,
                    to: selectionEnd
                )
                let hoverSuppressed = terminalPanel.hostedView.debugSimulateCommandHover(at: selectionEnd)
                payload["lastCommandSelectionActive"] = selectionActive ? "1" : "0"
                payload["lastCommandHoverSuppressed"] = hoverSuppressed ? "1" : "0"
                if selectionActive && hoverSuppressed {
                    payload["lastCommandSucceeded"] = "1"
                } else {
                    payload["lastCommandError"] = "Selection or hover suppression failed"
                }

            case "capture_window":
                let label = (command["label"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path = captureWindowSnapshotIfRequested(
                    label: label?.isEmpty == false ? label! : "capture",
                    window: window
                ) {
                    payload["lastCommandScreenshotPath"] = path
                    payload["lastCommandSucceeded"] = "1"
                } else {
                    payload["lastCommandError"] = "Window screenshot capture unavailable"
                }

            default:
                payload["lastCommandError"] = "Unknown command action: \(action)"
            }

            writeState(
                terminalPanel: terminalPanel,
                window: window,
                ready: true,
                additionalPayload: payload
            )
            lastHandledCommandID = commandID
        }

        @MainActor
        func evaluate() {
            guard !resolved else { return }
            let currentTabManager = self.tabManager
            let workspace = currentTabManager?.selectedWorkspace ?? currentTabManager?.tabs.first
            let terminalPanel = cmdClickUITestTerminalPanel(in: workspace)
            let mainWindow = terminalPanel?.surface.uiWindow
                ?? currentTabManager.flatMap { self.windowId(for: $0).flatMap { self.mainWindow(for: $0) } }
            if Date() >= deadline {
                let textSnapshot = terminalPanel
                    .flatMap { TerminalController.shared.readTerminalTextForSnapshot(terminalPanel: $0, lineLimit: 200) } ?? ""
                var timeoutPayload: [String: Any] = [:]
                if let currentTabManager {
                    timeoutPayload["tabManager"] = debugManagerToken(currentTabManager)
                    timeoutPayload["workspaceCount"] = currentTabManager.tabs.count
                }
                let waitingFor = [
                    workspace == nil ? "workspace" : nil,
                    terminalPanel == nil ? "terminalPanel" : nil,
                    mainWindow == nil ? "mainWindow" : nil
                ]
                    .compactMap { $0 }
                    .joined(separator: ",")
                if !waitingFor.isEmpty {
                    timeoutPayload["waitingFor"] = waitingFor
                }
                writeState(
                    terminalPanel: terminalPanel,
                    window: mainWindow,
                    ready: false,
                    setupError: "Timed out waiting for terminal cmd-click setup. text=\(textSnapshot)",
                    additionalPayload: timeoutPayload
                )
                resolved = true
                cleanup()
                return
            }

            if currentTabManager == nil {
                writeTerminalCmdClickUITestData(at: manifestPath, updates: [
                    "ready": "0",
                    "setupError": "Waiting for tab manager"
                ])
                return
            }

            guard let workspace,
                  let terminalPanel,
                  let mainWindow else {
                var waitingPayload: [String: Any] = [
                    "ready": "0",
                    "setupError": "Waiting for terminal workspace"
                ]
                if let currentTabManager {
                    waitingPayload["tabManager"] = debugManagerToken(currentTabManager)
                    waitingPayload["workspaceCount"] = currentTabManager.tabs.count
                }
                let waitingFor = [
                    workspace == nil ? "workspace" : nil,
                    terminalPanel == nil ? "terminalPanel" : nil,
                    mainWindow == nil ? "mainWindow" : nil
                ]
                    .compactMap { $0 }
                    .joined(separator: ",")
                if !waitingFor.isEmpty {
                    waitingPayload["waitingFor"] = waitingFor
                }
                writeTerminalCmdClickUITestData(at: manifestPath, updates: waitingPayload)
                return
            }

            resizeWindowIfNeeded(mainWindow)
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            terminalPanel.focus()

            do {
                try FileManager.default.createDirectory(
                    at: fixtureDirectoryURL,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: expectedFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: expectedFileURL.path) {
                    try "fixture\n".write(to: expectedFileURL, atomically: true, encoding: .utf8)
                }
                if !FileManager.default.fileExists(atPath: siblingFileURL.path) {
                    try "fixture\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
                }
                for extraFileName in extraFileNames where !extraFileName.isEmpty {
                    let extraFileURL = fixtureDirectoryURL.appendingPathComponent(extraFileName)
                    try FileManager.default.createDirectory(
                        at: extraFileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if !FileManager.default.fileExists(atPath: extraFileURL.path) {
                        try "fixture\n".write(to: extraFileURL, atomically: true, encoding: .utf8)
                    }
                }
            } catch {
                writeState(
                    terminalPanel: terminalPanel,
                    window: mainWindow,
                    ready: false,
                    setupError: "Failed to create fixture: \(error.localizedDescription)"
                )
                resolved = true
                cleanup()
                return
            }

            workspace.updatePanelDirectory(panelId: terminalPanel.id, directory: fixtureDirectoryURL.path)

            let terminalFrame = terminalPanel.hostedView.debugPortalFrameInWindow
            let terminalReady = terminalPanel.surface.surface != nil
            let terminalVisible = terminalPanel.surface.isViewInWindow &&
                terminalPanel.hostedView.debugPortalVisibleInUI &&
                !terminalFrame.isEmpty &&
                terminalFrame.width > 0 &&
                terminalFrame.height > 0

            if terminalReady && terminalVisible && !seeded {
                seeded = true
                sendTextWhenReady(shellCommand, to: workspace, beforeSend: {
                    workspace.updatePanelDirectory(panelId: terminalPanel.id, directory: fixtureDirectoryURL.path)
                })
            }

            let visibleText = TerminalController.shared.readTerminalTextForSnapshot(
                terminalPanel: terminalPanel,
                lineLimit: 200
            ) ?? ""
            let renderedTokenCount = max(0, visibleText.components(separatedBy: displayToken).count - 1)
            let hasRenderedToken = renderedTokenCount >= 6
            if hasRenderedToken,
               (tokenPointPayload?["tokenLayoutMatch"] as? String) != "1" {
                tokenPointPayload = tokenPoints(in: terminalPanel, visibleText: visibleText)
            }
            let tokenLayoutReady = (tokenPointPayload?["tokenLayoutMatch"] as? String) == "1"

            writeState(
                terminalPanel: terminalPanel,
                window: mainWindow,
                ready: terminalReady && terminalVisible && hasRenderedToken && tokenLayoutReady,
                additionalPayload: [
                    "seeded": seeded ? "1" : "0",
                    "hasRenderedToken": hasRenderedToken ? "1" : "0",
                    "renderedTokenCount": renderedTokenCount,
                    "visibleTextTail": String(visibleText.suffix(1200))
                ]
            )

            guard terminalReady, terminalVisible, hasRenderedToken, tokenLayoutReady else { return }
            if commandPath?.isEmpty == false {
                executePendingCommandIfNeeded(
                    workspace: workspace,
                    terminalPanel: terminalPanel,
                    window: mainWindow
                )
                return
            }
            resolved = true
            cleanup()
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        let poller = DispatchSource.makeTimerSource(queue: .main)
        poller.schedule(deadline: .now(), repeating: .milliseconds(100))
        poller.setEventHandler {
            Task { @MainActor in evaluate() }
        }
        terminalCmdClickUITestPoller = poller
        cmuxDebugLog("cmdclick.ui.setup poller_started manifest=\(manifestPath)")
        poller.resume()
    }

    private func writeTerminalCmdClickUITestData(at path: String, updates: [String: Any]) {
        let url = URL(fileURLWithPath: path)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            cmuxDebugLog("cmdclick.ui.write skip reason=json path=\(path)")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            cmuxDebugLog("cmdclick.ui.write error path=\(path) error=\(error.localizedDescription)")
        }
    }

    private func scheduleUITestSocketSanityCheckIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self else { return }
            guard let config = self.socketListenerConfigurationIfEnabled() else {
                self.writeUITestDiagnosticsIfNeeded(stage: "socketSanityDisabled")
                return
            }

            let expectedPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
            let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: expectedPath)
            let pingResponse = health.isHealthy
                ? socketTransport.probeCommand("ping", at: expectedPath, timeout: 1.0)
                : nil
            let isReady = health.isHealthy && pingResponse == "PONG"
            if isReady {
                self.writeUITestDiagnosticsIfNeeded(stage: "socketSanityReady")
                return
            }

            self.writeUITestDiagnosticsIfNeeded(stage: "socketSanityRestart")
            self.restartSocketListenerIfEnabled(source: "uiTest.socketSanity")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.writeUITestDiagnosticsIfNeeded(stage: "socketSanityPostRestart")
            }
        }
    }

    private func setupDisplayResolutionUITestDiagnosticsIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_DISPLAY_RENDER_STATS"] == "1" else { return }
        guard !didSetupDisplayResolutionUITestDiagnostics else { return }
        didSetupDisplayResolutionUITestDiagnostics = true

        let center = NotificationCenter.default
        let observe: (Notification.Name, String) -> Void = { [weak self] name, stage in
            guard let self else { return }
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.writeUITestDiagnosticsIfNeeded(stage: stage)
                }
            }
            self.displayResolutionUITestObservers.append(observer)
        }

        observe(NSWindow.didResizeNotification, "displayUITest.windowDidResize")
        observe(NSWindow.didMoveNotification, "displayUITest.windowDidMove")
        observe(NSWindow.didChangeScreenNotification, "displayUITest.windowDidChangeScreen")
        observe(NSWindow.didChangeBackingPropertiesNotification, "displayUITest.windowDidChangeBacking")
        observe(.terminalSurfaceDidBecomeReady, "displayUITest.terminalSurfaceDidBecomeReady")
        observe(.terminalPortalVisibilityDidChange, "displayUITest.terminalPortalVisibilityDidChange")

        writeUITestDiagnosticsIfNeeded(stage: "displayUITest.setup")
    }

    private func setupPortalStatsUITestDiagnosticsIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_PORTAL_STATS"] == "1" else { return }
        guard !didSetupPortalStatsUITestDiagnostics else { return }
        didSetupPortalStatsUITestDiagnostics = true

        let observer = NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.writeUITestDiagnosticsIfNeeded(stage: "feedSidebarUITest.terminalPortalVisibilityDidChange")
        }
        portalStatsUITestObservers.append(observer)
        writeUITestDiagnosticsIfNeeded(stage: "feedSidebarUITest.portalStats.setup")
    }

    private func setupFeedSidebarUITestIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard !didSetupFeedSidebarUITest else { return }
        guard let path = env["CMUX_UI_TEST_FEED_SIDEBAR_RESULT_PATH"], !path.isEmpty else { return }
        didSetupFeedSidebarUITest = true

        setupFeedSidebarUITestReveal(resultPath: path)
        writeFeedSidebarUITestData(["stage": "revealOnly"], at: path)
    }

    private func setupFeedSidebarUITestReveal(resultPath: String) {
        var observer: NSObjectProtocol?
        let attemptReveal: () -> Void = { [weak self] in
            guard let self else { return }
            let result = self.debugRevealRightSidebarInActiveMainWindow(
                mode: .dock,
                focusFirstItem: false,
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
            self.writeFeedSidebarUITestData([
                "reveal": result.revealed ? "1" : "0",
                "revealVisible": result.visible ? "1" : "0",
                "revealContextFound": result.contextFound ? "1" : "0",
                "revealStateFound": result.stateFound ? "1" : "0",
                "revealActiveMode": result.activeMode ?? "",
            ], at: resultPath)
            self.writeUITestDiagnosticsIfNeeded(
                stage: result.revealed ? "feedSidebarUITest.reveal.ok" : "feedSidebarUITest.reveal.pending"
            )
            if result.revealed {
                self.startFeedSidebarUITestPushIfNeeded(resultPath: resultPath)
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: self,
            queue: .main
        ) { _ in
            attemptReveal()
        }
        if let observer {
            feedSidebarUITestObservers.append(observer)
        }
        DispatchQueue.main.async(execute: attemptReveal)
    }

    private func startFeedSidebarUITestPushIfNeeded(resultPath: String) {
        let env = ProcessInfo.processInfo.environment
        guard !didStartFeedSidebarUITestPush else { return }
        guard let requestId = env["CMUX_UI_TEST_FEED_SIDEBAR_REQUEST_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !requestId.isEmpty else {
            return
        }
        didStartFeedSidebarUITestPush = true

        writeFeedSidebarUITestData([
            "pushStarted": "1",
            "pushRequestId": requestId,
        ], at: resultPath)
        observeFeedSidebarUITestPending(requestId: requestId, resultPath: resultPath)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var updates = Self.feedSidebarUITestPushUpdates(response: Self.runFeedSidebarUITestPush(requestId: requestId))
            if updates["pushResultStatus"] == "resolved" { updates["shortcutResponse"] = TerminalController.shared.handleSocketLine("simulate_shortcut ctrl+3") }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writeFeedSidebarUITestData(updates, at: resultPath)
                self.writeUITestDiagnosticsIfNeeded(stage: "feedSidebarUITest.push.finished")
            }
        }
    }

    private func observeFeedSidebarUITestPending(
        requestId: String,
        resultPath: String,
        remainingAttempts: Int = 75
    ) {
        let pending = FeedCoordinator.shared.snapshot(pendingOnly: false).contains { item in
            guard item.status.isPending else { return false }
            if case .permissionRequest(let itemRequestId, _, _, _) = item.payload {
                return itemRequestId == requestId
            }
            return false
        }
        if pending {
            writeFeedSidebarUITestData([
                "pushPendingObserved": "1",
            ], at: resultPath)
            return
        }
        guard remainingAttempts > 0 else {
            writeFeedSidebarUITestData([
                "pushPendingObserved": "0",
            ], at: resultPath)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.observeFeedSidebarUITestPending(
                requestId: requestId,
                resultPath: resultPath,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private static func runFeedSidebarUITestPush(requestId: String) -> String {
        let params: [String: Any] = [
            "event": [
                "session_id": "uitest-\(requestId)",
                "hook_event_name": "PermissionRequest",
                "_source": "claude",
                "tool_name": "Write",
                "tool_input": ["file_path": "/tmp/feeduitest"],
                "_opencode_request_id": requestId,
            ],
            "wait_timeout_seconds": 120,
        ]
        let frame: [String: Any] = [
            "id": UUID().uuidString,
            "method": "feed.push",
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let line = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"message\":\"failed to encode feed.push frame\"}}"
        }
        return TerminalController.shared.handleSocketLine(line)
    }

    private static func feedSidebarUITestPushUpdates(response: String) -> [String: String] {
        var updates: [String: String] = ["pushResponse": response]
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            updates["pushError"] = "invalid response: \(response)"
            return updates
        }
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? [String: Any]
            updates["pushError"] = (error?["message"] as? String) ?? "feed.push returned ok=false"
            return updates
        }
        guard let result = object["result"] as? [String: Any],
              let status = result["status"] as? String else {
            updates["pushError"] = "feed.push response missing result.status"
            return updates
        }
        updates["pushResultStatus"] = status
        if let decision = result["decision"] as? [String: Any],
           let mode = decision["mode"] as? String {
            updates["pushResultMode"] = mode
        }
        return updates
    }

    private func writeFeedSidebarUITestData(_ updates: [String: String], at path: String) {
        var payload: [String: String] = {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            return object
        }()
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
#endif

    private func prepareStartupSessionSnapshotIfNeeded() {
        guard !didPrepareStartupSessionSnapshot else { return }
        didPrepareStartupSessionSnapshot = true
        Self.removeLegacyPersistedWindowGeometry()
        syncManualRestoreSnapshotCachePruningCrashDiagnostics()
        let sanitizedStartupSnapshot = loadStartupSessionSnapshotPruningCrashDiagnostics()
        guard SessionRestorePolicy.shouldAttemptRestore() else { return }
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
        Self.removeLegacyPersistedWindowGeometry(defaults: defaults)
        guard let data = defaults.data(forKey: Self.persistedWindowGeometryDefaultsKey) else {
            return nil
        }
        guard let payload = Self.decodedPersistedWindowGeometryData(data) else {
            defaults.removeObject(forKey: Self.persistedWindowGeometryDefaultsKey)
            return nil
        }
        return payload
    }

    private func persistWindowGeometry(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?,
        defaults: UserDefaults = .standard
    ) {
        Self.removeLegacyPersistedWindowGeometry(defaults: defaults)
        guard let data = Self.encodedPersistedWindowGeometryData(frame: frame, display: display) else {
            return
        }
        defaults.set(data, forKey: Self.persistedWindowGeometryDefaultsKey)
    }

    private nonisolated static func encodedPersistedWindowGeometryData(
        frame: SessionRectSnapshot?,
        display: SessionDisplaySnapshot?
    ) -> Data? {
        guard let frame else { return nil }
        let payload = PersistedWindowGeometry(
            version: persistedWindowGeometrySchemaVersion,
            frame: frame,
            display: display
        )
        return try? JSONEncoder().encode(payload)
    }

    nonisolated static func decodedPersistedWindowGeometryData(_ data: Data) -> PersistedWindowGeometry? {
        guard let payload = try? JSONDecoder().decode(PersistedWindowGeometry.self, from: data),
              payload.version == persistedWindowGeometrySchemaVersion else {
            return nil
        }
        return payload
    }

    private nonisolated static func removeLegacyPersistedWindowGeometry(
        defaults: UserDefaults = .standard
    ) {
        legacyPersistedWindowGeometryDefaultsKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    private func persistWindowGeometry(from window: NSWindow?) {
        guard let window else { return }
        persistWindowGeometry(
            frame: SessionRectSnapshot(window.frame),
            display: displaySnapshot(for: window)
        )
    }

    func currentDisplayGeometries() -> (available: [SessionDisplayGeometry], fallback: SessionDisplayGeometry?) {
        let available = NSScreen.screens.map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                stableID: screen.cmuxStableDisplayKey,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        let fallback = (NSScreen.main ?? NSScreen.screens.first).map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                stableID: screen.cmuxStableDisplayKey,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        return (available, fallback)
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
                    "primaryFrame={\(sessionRectLogDescription(primaryWindowSnapshot.frame))} " +
                    "primaryDisplay={\(debugSessionDisplayDescription(primaryWindowSnapshot.display))}"
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
                    "frame={\(sessionRectLogDescription(windowSnapshot.frame))} " +
                    "display={\(debugSessionDisplayDescription(windowSnapshot.display))}"
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
            // A display change arrived mid-restore and its reconcile pass was
            // skipped. Queue it now that restore is done
            // so remembered frames for the new configuration are applied and
            // `lastAppliedConfigurationSignature` catches up.
            scheduleScreenChangeReconcileWhenIdle()
        }
        flushPendingStartupNavigationURLRequests()
        if Self.shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: isManualReopen) {
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
        guard let snapshot = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(from: snapshot).snapshot else {
            return false
        }
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
            NSRunningApplication.current.activate(
                options: [.activateAllWindows, .activateIgnoringOtherApps]
            )
        }

        return true
    }

    private func applySessionWindowSnapshot(
        _ snapshot: SessionWindowSnapshot,
        to context: MainWindowContext,
        window: NSWindow?
    ) {
#if DEBUG
        cmuxDebugLog(
            "session.restore.apply window=\(context.windowId.uuidString.prefix(8)) " +
                "liveWin=\(window?.windowNumber ?? -1) " +
                "snapshotFrame={\(sessionRectLogDescription(snapshot.frame))} " +
                "snapshotDisplay={\(debugSessionDisplayDescription(snapshot.display))}"
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
            ClosedItemHistoryStore.shared.remapWorkspaceWindowIds(from: originalWindowId, to: context.windowId)
            ClosedItemHistoryStore.shared.flushPendingSaves()
        }
        context.sidebarState.isVisible = snapshot.sidebar.isVisible
        context.sidebarState.persistedWidth = CGFloat(
            SessionPersistencePolicy.sanitizedSidebarWidth(snapshot.sidebar.width)
        )
        context.sidebarSelectionState.selection = snapshot.sidebar.selection.sidebarSelection

        if let restoredFrame = resolvedWindowFrame(from: snapshot), let window {
            window.setFrame(restoredFrame, display: true)
#if DEBUG
            cmuxDebugLog(
                "session.restore.frameApplied window=\(context.windowId.uuidString.prefix(8)) " +
                    "applied={\(nsRectLogDescription(window.frame))}"
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

    nonisolated static func resolvedStartupPrimaryWindowFrame(
        primarySnapshot: SessionWindowSnapshot?,
        fallbackFrame: SessionRectSnapshot?,
        fallbackDisplaySnapshot: SessionDisplaySnapshot?,
        availableDisplays: [SessionDisplayGeometry],
        fallbackDisplay: SessionDisplayGeometry?,
        isMirrored: Bool = false
    ) -> CGRect? {
        if let primary = resolvedWindowFrame(
            from: primarySnapshot,
            currentSignature: availableDisplays.displayConfigurationSignature(isMirrored: isMirrored),
            availableDisplays: availableDisplays,
            fallbackDisplay: fallbackDisplay
        ) {
            return primary
        }

        return resolvedWindowFrame(
            from: fallbackFrame,
            display: fallbackDisplaySnapshot,
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
        guard let frameSnapshot else { return nil }
        let frame = frameSnapshot.cgRect
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite else {
            return nil
        }

        let minWidth = CGFloat(SessionPersistencePolicy.minimumWindowWidth)
        let minHeight = CGFloat(SessionPersistencePolicy.minimumWindowHeight)
        guard frame.width >= minWidth,
              frame.height >= minHeight else {
            return nil
        }

        guard !availableDisplays.isEmpty else { return frame }

        if let targetDisplay = display(for: displaySnapshot, in: availableDisplays) {
            if shouldPreserveExactFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return resolvedWindowFrame(
                frame: frame,
                displaySnapshot: displaySnapshot,
                targetDisplay: targetDisplay,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let intersectingDisplay = availableDisplays.first(where: { $0.visibleFrame.intersects(frame) }) {
            return clampFrame(
                frame,
                within: intersectingDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        guard let fallbackDisplay else { return frame }
        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: fallbackDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: fallbackDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func resolvedWindowFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        if targetDisplay.visibleFrame.intersects(frame) {
            // Preserve exact frames whose titlebar remains reachable.
            if shouldPreserveAccessibleFrame(
                frame: frame,
                targetDisplay: targetDisplay
            ) {
                return frame
            }
            return clampFrame(
                frame,
                within: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        if let sourceReference = displaySnapshot?.visibleFrame?.cgRect ?? displaySnapshot?.frame?.cgRect {
            return remappedFrame(
                frame,
                from: sourceReference,
                to: targetDisplay.visibleFrame,
                minWidth: minWidth,
                minHeight: minHeight
            )
        }

        return centeredFrame(
            frame,
            in: targetDisplay.visibleFrame,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    private nonisolated static func display(
        for snapshot: SessionDisplaySnapshot?,
        in displays: [SessionDisplayGeometry]
    ) -> SessionDisplayGeometry? {
        guard let snapshot else { return nil }
        if let stableID = snapshot.stableID, !stableID.isEmpty {
            let matches = displays.filter { $0.stableID == stableID }
            if matches.count == 1 { return matches[0] }
            if let geometryMatch = displayMatchingSnapshotGeometry(for: snapshot, in: matches) {
                return geometryMatch
            }
            let unidentifiedDisplays = displays.filter { ($0.stableID ?? "").isEmpty }
            return displayMatchingSnapshotGeometry(for: snapshot, in: unidentifiedDisplays)
        }
        if let displayID = snapshot.displayID,
           let exact = displays.first(where: { $0.displayID == displayID }) {
            return exact
        }
        return displayMatchingSnapshotGeometry(for: snapshot, in: displays)
    }

    private nonisolated static func remappedFrame(
        _ frame: CGRect,
        from sourceRect: CGRect,
        to targetRect: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let source = sourceRect.standardized
        let target = targetRect.standardized
        guard source.width.isFinite,
              source.height.isFinite,
              source.width > 1,
              source.height > 1,
              target.width.isFinite,
              target.height.isFinite,
              target.width > 0,
              target.height > 0 else {
            return centeredFrame(frame, in: targetRect, minWidth: minWidth, minHeight: minHeight)
        }

        let relativeX = (frame.minX - source.minX) / source.width
        let relativeY = (frame.minY - source.minY) / source.height
        let relativeWidth = frame.width / source.width
        let relativeHeight = frame.height / source.height

        let remapped = CGRect(
            x: target.minX + (relativeX * target.width),
            y: target.minY + (relativeY * target.height),
            width: target.width * relativeWidth,
            height: target.height * relativeHeight
        )
        return clampFrame(remapped, within: target, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func centeredFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect {
        let centered = CGRect(
            x: visibleFrame.midX - (frame.width / 2),
            y: visibleFrame.midY - (frame.height / 2),
            width: frame.width,
            height: frame.height
        )
        return clampFrame(centered, within: visibleFrame, minWidth: minWidth, minHeight: minHeight)
    }

    private nonisolated static func shouldPreserveExactFrame(
        frame: CGRect,
        displaySnapshot: SessionDisplaySnapshot?,
        targetDisplay: SessionDisplayGeometry
    ) -> Bool {
        guard let displaySnapshot else { return false }
        if let stableID = displaySnapshot.stableID, !stableID.isEmpty {
            guard targetDisplay.stableID == stableID else { return false }
        } else {
            guard let snapshotDisplayID = displaySnapshot.displayID,
                  let targetDisplayID = targetDisplay.displayID,
                  snapshotDisplayID == targetDisplayID else { return false }
        }

        let visibleMatches = displaySnapshot.visibleFrame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.visibleFrame)
        } ?? false
        let frameMatches = displaySnapshot.frame.map {
            rectApproximatelyEqual($0.cgRect, targetDisplay.frame)
        } ?? false
        guard visibleMatches || frameMatches else { return false }

        return frame.width.isFinite
            && frame.height.isFinite
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
    }

    private nonisolated static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let lhsStd = lhs.standardized
        let rhsStd = rhs.standardized
        return abs(lhsStd.origin.x - rhsStd.origin.x) <= tolerance
            && abs(lhsStd.origin.y - rhsStd.origin.y) <= tolerance
            && abs(lhsStd.size.width - rhsStd.size.width) <= tolerance
            && abs(lhsStd.size.height - rhsStd.size.height) <= tolerance
    }

    private func startSessionAutosaveTimerIfNeeded() {
        guard sessionAutosaveTimer == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard !isRunningUnderXCTest(env) else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = SessionPersistencePolicy.autosaveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self,
                  Self.shouldRunSessionAutosaveTick(isTerminatingApp: self.isTerminatingApp) else {
                return
            }
            self.runSessionAutosaveTick(source: "timer")
        }
        sessionAutosaveTimer = timer
        timer.resume()
    }

    private func stopSessionAutosaveTimer() {
        sessionAutosaveTimer?.cancel()
        sessionAutosaveTimer = nil
        sessionAutosaveTickInFlight = false
        sessionAutosaveDeferredRetryPending = false
    }

    private func installLifecycleSnapshotObserversIfNeeded() {
        guard !didInstallLifecycleSnapshotObservers else { return }
        didInstallLifecycleSnapshotObservers = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let powerOffObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTerminatingApp = true
                _ = self.saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
                ClosedItemHistoryStore.shared.flushPendingSaves()
            }
        }
        lifecycleSnapshotObservers.append(powerOffObserver)

        let sessionResignObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTerminatingApp {
                    _ = self.saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
                    ClosedItemHistoryStore.shared.flushPendingSaves()
                } else {
                    self.saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
                }
            }
        }
        lifecycleSnapshotObservers.append(sessionResignObserver)

        let didWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartSocketListenerIfEnabled(source: "workspace.didWake")
            }
        }
        lifecycleSnapshotObservers.append(didWakeObserver)

        registerDisplayReconfigurationCallbackIfNeeded()
        let displayReconfigurationObserver = NotificationCenter.default.addObserver(
            forName: Self.displayReconfigurationNotification,
            object: self,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isBeginning = note.userInfo?["isBeginning"] as? Bool ?? false
                self.handleDisplayReconfiguration(isBeginning: isBeginning)
            }
        }
        lifecycleSnapshotObservers.append(displayReconfigurationObserver)

        let screenReconcileObserver = NotificationCenter.default.addObserver(
            forName: Self.screenChangeReconcileNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileMainWindowFramesAfterScreenChange()
            }
        }
        lifecycleSnapshotObservers.append(screenReconcileObserver)

        let screenParamsObserver = NotificationCenter.default.addObserver(
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
        lifecycleSnapshotObservers.append(screenParamsObserver)
    }

    private func socketListenerConfigurationIfEnabled() -> (mode: SocketControlMode, path: String)? {
        let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        let userMode = SocketControlSettings.migrateMode(raw)
        let mode = SocketControlSettings.effectiveMode(userMode: userMode)
        guard mode != .off else { return nil }
        return (mode: mode, path: SocketControlSettings.socketPath())
    }

    private func reserveInitialSocketPathIfNeeded() {
        guard let config = socketListenerConfigurationIfEnabled() else { return }
        let startupPath = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: config.path,
            stableDefaultSocketCanBeReclaimed: socketTransport.pathCanBeReclaimedForStartup
        )
        TerminalController.shared.reserveStartupSocketPath(startupPath)
    }

    private func startSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop()
            return
        }
        let path = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        sentryBreadcrumb("socket.listener.start", category: "socket", data: [
            "mode": config.mode.rawValue,
            "path": path,
            "source": source
        ])
        TerminalController.shared.start(tabManager: tabManager, socketPath: path, accessMode: config.mode)
    }

    private func ensureSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop()
            return
        }

        let path = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        guard !health.isHealthy else { return }

        sentryBreadcrumb("socket.listener.ensure", category: "socket", data: [
            "mode": config.mode.rawValue,
            "path": path,
            "source": source,
            "failureSignals": health.failureSignals.joined(separator: ",")
        ])
        TerminalController.shared.start(tabManager: tabManager, socketPath: path, accessMode: config.mode)
    }

    private func restartSocketListenerIfEnabled(source: String) {
        guard let manager = tabManager
            ?? preferredRegisteredMainWindowContext()?.tabManager
            ?? mainWindowContexts.values.first?.tabManager,
              let config = socketListenerConfigurationIfEnabled() else { return }
        let restartPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        sentryBreadcrumb("socket.listener.restart", category: "socket", data: [
            "mode": config.mode.rawValue,
            "path": restartPath,
            "source": source
        ])
        TerminalController.shared.stop()
        TerminalController.shared.start(tabManager: manager, socketPath: restartPath, accessMode: config.mode)
    }

    private func disableSuddenTerminationIfNeeded() {
        guard !didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.disableSuddenTermination()
        didDisableSuddenTermination = true
    }

    private func enableSuddenTerminationIfNeeded() {
        guard didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
        didDisableSuddenTermination = false
    }

    private func sessionAutosaveFingerprint(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    ) -> Int? {
        guard !includeScrollback else { return nil }

        var hasher = Hasher()
        let contexts = mainWindowContexts.values.sorted { lhs, rhs in
            lhs.windowId.uuidString < rhs.windowId.uuidString
        }
        hasher.combine(contexts.count)

        for context in contexts.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            hasher.combine(context.windowId)
            hasher.combine(
                context.tabManager.sessionAutosaveFingerprint(
                    restorableAgentIndex: restorableAgentIndex,
                    surfaceResumeBindingIndex: surfaceResumeBindingIndex
                )
            )
            hasher.combine(context.sidebarState.isVisible)
            hasher.combine(
                Int(SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth)).rounded())
            )

            switch context.sidebarSelectionState.selection {
            case .tabs:
                hasher.combine(0)
            case .notifications:
                hasher.combine(1)
            }

            if let window = context.window ?? windowForMainWindowId(context.windowId) {
                Self.hashFrame(window.frame, into: &hasher)
            } else {
                hasher.combine(-1)
            }
        }

        return hasher.finalize()
    }

    @discardableResult
    private func saveSessionSnapshot(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false,
        preserveManualRestoreBackupOnMissingPrimary: Bool = false,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> Bool {
        if Self.shouldSkipSessionSaveDuringRestore(
            isApplyingSessionRestore: isApplyingSessionRestore,
            includeScrollback: includeScrollback
        ) {
#if DEBUG
            cmuxDebugLog("session.save.skipped reason=session_restore_in_progress includeScrollback=0")
#endif
            return false
        }
        let writeSynchronously = Self.shouldWriteSessionSnapshotSynchronously(
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

    nonisolated static func shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldSaveSessionSnapshotAfterMainWindowRegistration(
        isTerminatingApp: Bool,
        didApplyStartupSessionRestore: Bool,
        isApplyingSessionRestore: Bool
    ) -> Bool {
        !isTerminatingApp && !didApplyStartupSessionRestore && !isApplyingSessionRestore
    }

    nonisolated static func shouldRunSessionAutosaveTick(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp _: Bool) -> Bool {
        // App switching must stay cheap. The autosave timer, window/session lifecycle,
        // power-off, update relaunch, and termination paths still persist session state.
        false
    }

    private func remainingSessionAutosaveTypingQuietPeriod(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = nowUptime - lastTypingActivityAt
        guard elapsed < Self.sessionAutosaveTypingQuietPeriod else { return nil }
        return Self.sessionAutosaveTypingQuietPeriod - elapsed
    }

    private func scheduleDeferredSessionAutosaveRetry(after delay: TimeInterval) {
        guard delay.isFinite, delay > 0 else { return }
        guard !sessionAutosaveDeferredRetryPending else { return }
        sessionAutosaveDeferredRetryPending = true
        sessionPersistenceQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionAutosaveDeferredRetryPending = false
                self.runSessionAutosaveTick(source: "typingQuietRetry")
            }
        }
    }

    private func runSessionAutosaveTick(source: String) {
        guard Self.shouldRunSessionAutosaveTick(isTerminatingApp: isTerminatingApp) else { return }
        guard !sessionAutosaveTickInFlight else { return }
        if let remainingQuietPeriod = remainingSessionAutosaveTypingQuietPeriod() {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=typing_recent includeScrollback=0 source=\(source) " +
                "retryMs=\(Int((remainingQuietPeriod * 1000).rounded()))"
            )
#endif
            scheduleDeferredSessionAutosaveRetry(after: remainingQuietPeriod)
            return
        }

        sessionAutosaveTickInFlight = true
        let generation = nextProcessDetectedSessionSaveGeneration()
        Task { @MainActor in await self.finishSessionAutosaveTick(source: source, generation: generation) }
    }

    private func finishSessionAutosaveTick(source: String, generation: UInt64) async {
#if DEBUG
        let timingStart = CmuxTypingTiming.start()
        let phaseStart = ProcessInfo.processInfo.systemUptime
        var fingerprintMs: Double = 0
        var saveMs: Double = 0
        defer {
            sessionAutosaveTickInFlight = false
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
#else
        defer { sessionAutosaveTickInFlight = false }
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
        if Self.shouldSkipSessionAutosaveForUnchangedFingerprint(
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

    @discardableResult
    private func saveSessionSnapshotIncludingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false
    ) -> Bool {
        let resumeIndexes = ProcessDetectedResumeIndexes.loadSynchronously()
        return saveSessionSnapshot(
            includeScrollback: includeScrollback,
            removeWhenEmpty: removeWhenEmpty,
            restorableAgentIndex: resumeIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
        )
    }

    private func saveSessionSnapshotAfterLoadingProcessDetectedIndexes(
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
        lastTypingActivityAt = ProcessInfo.processInfo.systemUptime
    }

    nonisolated static func shouldWriteSessionSnapshotSynchronously(
        isTerminatingApp: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isTerminatingApp && includeScrollback
    }

    nonisolated static func shouldSkipSessionAutosaveForUnchangedFingerprint(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        previousFingerprint: Int?,
        currentFingerprint: Int?,
        lastPersistedAt: Date,
        now: Date,
        maximumAutosaveSkippableInterval: TimeInterval = 60
    ) -> Bool {
        guard !isTerminatingApp,
              !includeScrollback,
              let previousFingerprint,
              let currentFingerprint,
              previousFingerprint == currentFingerprint else {
            return false
        }

        return now.timeIntervalSince(lastPersistedAt) < maximumAutosaveSkippableInterval
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

    private nonisolated static func hashFrame(_ frame: NSRect, into hasher: inout Hasher) {
        let standardized = frame.standardized
        let quantized = [
            standardized.origin.x,
            standardized.origin.y,
            standardized.size.width,
            standardized.size.height,
        ].map { Int(($0 * 2).rounded()) }
        quantized.forEach { hasher.combine($0) }
    }

    private func persistSessionSnapshot(
        _ snapshot: AppSessionSnapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool,
        preserveManualRestoreBackupOnMissingPrimary: Bool = false
    ) {
        guard snapshot != nil || removeWhenEmpty || persistedGeometryData != nil else { return }

        let writeBlock = {
            Self.removeLegacyPersistedWindowGeometry()
            if let persistedGeometryData {
                UserDefaults.standard.set(
                    persistedGeometryData,
                    forKey: Self.persistedWindowGeometryDefaultsKey
                )
            }
            if let snapshot {
                Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
                _ = self.sessionSnapshotStore.save(snapshot, fileURL: nil)
            } else if removeWhenEmpty {
                if preserveManualRestoreBackupOnMissingPrimary {
                    Self.markCrashOnlyPrimarySnapshotRemoval()
                } else {
                    Self.clearCrashOnlyPrimarySnapshotRemovalMarker()
                }
                self.sessionSnapshotStore.removeSnapshot(fileURL: nil)
            }
        }

        if synchronously {
            writeBlock()
        } else {
            sessionPersistenceQueue.async(execute: writeBlock)
        }
    }

    func sortedMainWindowContextsForSessionSnapshot() -> [MainWindowContext] {
        mainWindowContexts.values.sorted { lhs, rhs in
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

        var windows: [SessionWindowSnapshot] = []
        var removedCrashDiagnosticState = false
        let createdAt = Date().timeIntervalSince1970
        for context in contexts {
            let windowSnapshot = sessionWindowSnapshot(
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
            if remoteTmuxController.isDedicatedRemoteWindow(context.windowId),
               windowSnapshot.tabManager.workspaces.isEmpty {
                continue
            }

            let pruned = SessionPersistencePolicy.pruningCmuxCrashDiagnosticWindows(
                from: AppSessionSnapshot(
                    version: SessionSnapshotSchema.currentVersion,
                    createdAt: createdAt,
                    windows: [windowSnapshot]
                )
            )
            removedCrashDiagnosticState = removedCrashDiagnosticState || pruned.removedAny
            guard let prunedWindow = pruned.snapshot?.windows.first else { continue }
            windows.append(prunedWindow)
            if windows.count >= SessionPersistencePolicy.maxWindowsPerSnapshot {
                break
            }
        }

        guard !windows.isEmpty else { return (nil, removedCrashDiagnosticState) }
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: createdAt,
            windows: windows
        )
        return (snapshot, removedCrashDiagnosticState)
    }

    private func sessionWindowSnapshot(
        for context: MainWindowContext,
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
        // Fold the live window's current frame into its per-config ring so the
        // saved snapshot always carries the freshest geometry for the current
        // configuration (subject to the capture firewall).
        if let window {
            captureWindowConfigFrame(window, reason: "sessionSnapshot")
        }
        return SessionWindowSnapshot(
            windowId: context.windowId,
            frame: window.map { SessionRectSnapshot($0.frame) },
            display: displaySnapshot(for: window),
            tabManager: tabManagerSnapshot,
            sidebar: SessionSidebarSnapshot(
                isVisible: context.sidebarState.isVisible,
                selection: SessionSidebarSelection(selection: context.sidebarSelectionState.selection),
                width: SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth))
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
                    "display={\(debugSessionDisplayDescription(windowSnapshot.display))} " +
                    "workspaces=\(workspaceCount) selected=\(selectedWorkspace)"
            )
        }
    }

    func sessionRectLogDescription(_ rect: SessionRectSnapshot?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(rect.x)) y=\(debugSessionNumber(rect.y)) " +
            "w=\(debugSessionNumber(rect.width)) h=\(debugSessionNumber(rect.height))"
    }

    func nsRectLogDescription(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(Double(rect.origin.x))) " +
            "y=\(debugSessionNumber(Double(rect.origin.y))) " +
            "w=\(debugSessionNumber(Double(rect.size.width))) " +
            "h=\(debugSessionNumber(Double(rect.size.height)))"
    }

    private func debugSessionDisplayDescription(_ display: SessionDisplaySnapshot?) -> String {
        guard let display else { return "nil" }
        let displayIdText = display.displayID.map(String.init) ?? "nil"
        return "id=\(displayIdText) " +
            "frame={\(sessionRectLogDescription(display.frame))} " +
            "visible={\(sessionRectLogDescription(display.visibleFrame))}"
    }

    private func debugSessionNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
#endif

    // Internal (not private): the test target's main-window testing seams
    // (cmuxTests/AppDelegateMainWindowTestingSupport.swift, via @testable
    // import) drive the same registration paths.
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
        guard !mainWindowContexts.values.contains(where: { $0.tabManager === tabManager }) else {
            return
        }
        mobileWorkspaceListObservers.removeValue(forKey: ObjectIdentifier(tabManager))
    }

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        fileExplorerState: FileExplorerState? = nil,
        cmuxConfigStore: CmuxConfigStore? = nil
    ) {
        let key = ObjectIdentifier(window)
        forgetRecoverableMainWindowRoute(windowId: windowId)
        #if DEBUG
        let priorManagerToken = debugManagerToken(self.tabManager)
        #endif
        if let existing = mainWindowContexts[key] {
            tabManager.window = window
            tabManager.windowId = existing.windowId
            existing.window = window
            let resolvedFileExplorerState = fileExplorerState ?? existing.fileExplorerState
            if let fileExplorerState {
                existing.fileExplorerState = fileExplorerState
            }
            existing.keyboardFocusCoordinator.update(
                window: window,
                tabManager: tabManager,
                fileExplorerState: resolvedFileExplorerState
            )
            if let cmuxConfigStore {
                existing.cmuxConfigStore = cmuxConfigStore
            }
            existing.closeObserver = WindowCloseObserver(window: window) { [weak self] in self?.unregisterMainWindow($0) }
        } else if let existing = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            if let existingWindow = existing.window,
               existingWindow !== window,
               existingWindow.isVisible || existingWindow.isMiniaturized {
#if DEBUG
                cmuxDebugLog(
                    "mainWindow.register.duplicateIgnored windowId=\(String(windowId.uuidString.prefix(8))) " +
                        "existing={\(debugWindowToken(existingWindow))} duplicate={\(debugWindowToken(window))}"
                )
#endif
                existing.tabManager.window = existingWindow
                existing.tabManager.windowId = existing.windowId
                existing.keyboardFocusCoordinator.update(
                    window: existingWindow,
                    tabManager: existing.tabManager,
                    fileExplorerState: existing.fileExplorerState
                )
                window.orderOut(nil)
                window.close()
                return
            }
            tabManager.window = window
            tabManager.windowId = windowId
            existing.window = window
            let resolvedFileExplorerState = fileExplorerState ?? existing.fileExplorerState
            if let fileExplorerState {
                existing.fileExplorerState = fileExplorerState
            }
            existing.keyboardFocusCoordinator.update(
                window: window,
                tabManager: tabManager,
                fileExplorerState: resolvedFileExplorerState
            )
            if let cmuxConfigStore {
                existing.cmuxConfigStore = cmuxConfigStore
            }
            reindexMainWindowContextIfNeeded(existing, for: window)
            existing.closeObserver = WindowCloseObserver(window: window) { [weak self] in self?.unregisterMainWindow($0) }
        } else {
            tabManager.window = window
            tabManager.windowId = windowId
            let context = MainWindowContext(
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                fileExplorerState: fileExplorerState,
                cmuxConfigStore: cmuxConfigStore,
                window: window
            )
            mainWindowContexts[key] = context
            context.closeObserver = WindowCloseObserver(window: window) { [weak self] in self?.unregisterMainWindow($0) }
        }
        commandPaletteWindowStore.registerWindow(windowId)

#if DEBUG
        cmuxDebugLog(
            "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(priorManagerToken) \(debugShortcutRouteSnapshot())"
        )
#endif
        ensureSocketListenerIfEnabled(tabManager: tabManager, source: "mainWindow.register")
        ensureMobileWorkspaceListObserver(for: tabManager)
        notifyMainWindowContextsDidChange()
        if window.isKeyWindow {
            setActiveMainWindow(window)
        }

        let didApplyStartupSessionRestore = attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
        if Self.shouldSaveSessionSnapshotAfterMainWindowRegistration(
            isTerminatingApp: isTerminatingApp,
            didApplyStartupSessionRestore: didApplyStartupSessionRestore,
            isApplyingSessionRestore: isApplyingSessionRestore
        ) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
        }
    }

#if DEBUG
    func sessionSnapshotForTesting(includeScrollback: Bool = false) -> AppSessionSnapshot? {
        buildSessionSnapshot(includeScrollback: includeScrollback)
    }
#endif

    /// Lifted to ``CmuxWindowing/MainWindowSummary``; aliased so existing
    /// `AppDelegate.MainWindowSummary` references stay source-identical.
    typealias MainWindowSummary = CmuxWindowing.MainWindowSummary

    struct WindowMoveTarget: Identifiable {
        let windowId: UUID
        let label: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        var id: UUID { windowId }
    }

    struct WorkspaceMoveTarget: Identifiable {
        let windowId: UUID
        let workspaceId: UUID
        let windowLabel: String
        let workspaceTitle: String
        let tabManager: TabManager
        let isCurrentWindow: Bool

        var id: String { "\(windowId.uuidString):\(workspaceId.uuidString)" }
        var label: String {
            isCurrentWindow ? workspaceTitle : "\(workspaceTitle) (\(windowLabel))"
        }
    }

    func windowMoveTargets(referenceWindowId: UUID?) -> [WindowMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)
        return orderedSummaries.compactMap { summary in
            guard let manager = tabManagerFor(windowId: summary.windowId) else { return nil }
            let label = labels[summary.windowId] ?? "Window"
            return WindowMoveTarget(
                windowId: summary.windowId,
                label: label,
                tabManager: manager,
                isCurrentWindow: summary.windowId == referenceWindowId
            )
        }
    }

    func workspaceMoveTargets(excludingWorkspaceId: UUID? = nil, referenceWindowId: UUID?) -> [WorkspaceMoveTarget] {
        let orderedSummaries = orderedMainWindowSummaries(referenceWindowId: referenceWindowId)
        let labels = windowLabelsById(orderedSummaries: orderedSummaries, referenceWindowId: referenceWindowId)

        var targets: [WorkspaceMoveTarget] = []
        targets.reserveCapacity(orderedSummaries.reduce(0) { partial, summary in
            partial + summary.workspaceCount
        })

        for summary in orderedSummaries {
            guard let manager = tabManagerFor(windowId: summary.windowId) else { continue }
            let windowLabel = labels[summary.windowId] ?? "Window"
            let isCurrentWindow = summary.windowId == referenceWindowId
            for workspace in manager.tabs {
                if workspace.id == excludingWorkspaceId {
                    continue
                }
                targets.append(
                    WorkspaceMoveTarget(
                        windowId: summary.windowId,
                        workspaceId: workspace.id,
                        windowLabel: windowLabel,
                        workspaceTitle: workspaceDisplayName(workspace),
                        tabManager: manager,
                        isCurrentWindow: isCurrentWindow
                    )
                )
            }
        }

        return targets
    }

    @discardableResult
    func moveWorkspaceToWindow(workspaceId: UUID, windowId: UUID, atIndex: Int? = nil, focus: Bool = true) -> Bool {
        guard let sourceManager = tabManagerFor(tabId: workspaceId),
              let destinationManager = tabManagerFor(windowId: windowId) else {
            return false
        }

        if sourceManager === destinationManager {
            if focus {
                destinationManager.focusTab(workspaceId, suppressFlash: true)
                _ = focusMainWindow(windowId: windowId)
                TerminalController.shared.setActiveTabManager(destinationManager)
            }
            return true
        }

        guard let workspace = sourceManager.detachWorkspace(tabId: workspaceId) else { return false }
        destinationManager.attachWorkspace(workspace, at: atIndex, select: focus)

        if focus {
            _ = focusMainWindow(windowId: windowId)
            TerminalController.shared.setActiveTabManager(destinationManager)
        }
        return true
    }

    @discardableResult
    func moveWorkspaceToNewWindow(workspaceId: UUID, focus: Bool = true) -> UUID? {
        let windowId = createMainWindow()
        guard let destinationManager = tabManagerFor(windowId: windowId) else { return nil }
        let bootstrapWorkspaceId = destinationManager.tabs.first?.id

        guard moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: focus) else {
            _ = closeMainWindow(windowId: windowId, recordHistory: false)
            return nil
        }

        // Remove the bootstrap workspace from the new window once the moved workspace arrives.
        if let bootstrapWorkspaceId,
           bootstrapWorkspaceId != workspaceId,
           let bootstrapWorkspace = destinationManager.tabs.first(where: { $0.id == bootstrapWorkspaceId }),
           destinationManager.tabs.count > 1 {
            destinationManager.closeWorkspace(bootstrapWorkspace, recordHistory: false)
        }
        return windowId
    }

    func locateBonsplitSurface(tabId: UUID) -> (windowId: UUID, workspaceId: UUID, panelId: UUID, tabManager: TabManager)? {
        let bonsplitTabId = TabID(uuid: tabId)
        for context in mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (context.windowId, workspace.id, panelId, context.tabManager)
                }
            }
        }
        for route in recoverableMainWindowRoutes() {
            guard let manager = route.tabManager else { continue }
            for workspace in manager.tabs {
                if let panelId = workspace.panelIdFromSurfaceId(bonsplitTabId) {
                    return (route.windowId, workspace.id, panelId, manager)
                }
            }
        }
        return nil
    }

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
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        let splitLabel = splitTarget.map { split in
            "\(split.orientation.rawValue):\(split.insertFirst ? 1 : 0)"
        } ?? "none"
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        cmuxDebugLog(
            "surface.move.begin panel=\(panelId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
            "split=\(splitLabel) focus=\(focus ? 1 : 0) focusWindow=\(focusWindow ? 1 : 0)"
        )
#endif
        guard let source = locateSurface(surfaceId: panelId) else {
#if DEBUG
            cmuxDebugLog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourcePanelNotFound elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let sourceWorkspace = source.tabManager.tabs.first(where: { $0.id == source.workspaceId }) else {
#if DEBUG
            cmuxDebugLog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sourceWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let destinationManager = tabManagerFor(tabId: targetWorkspaceId) else {
#if DEBUG
            cmuxDebugLog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationManagerMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
        guard let destinationWorkspace = destinationManager.tabs.first(where: { $0.id == targetWorkspaceId }) else {
#if DEBUG
            cmuxDebugLog("surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=destinationWorkspaceMissing elapsedMs=\(elapsedMs(since: moveStart))")
#endif
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "surface.move.route panel=\(panelId.uuidString.prefix(5)) sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) " +
            "sourceWin=\(source.windowId.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
            "sameWorkspace=\(destinationWorkspace.id == sourceWorkspace.id ? 1 : 0)"
        )
#endif

        let resolvedTargetPane = targetPane.flatMap { pane in
            destinationWorkspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? destinationWorkspace.bonsplitController.focusedPaneId
            ?? destinationWorkspace.bonsplitController.allPaneIds.first

        guard let resolvedTargetPane else {
#if DEBUG
            cmuxDebugLog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=targetPaneMissing " +
                "destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }

        if destinationWorkspace.id == sourceWorkspace.id {
            if let splitTarget {
                guard let sourceTabId = sourceWorkspace.surfaceIdFromPanelId(panelId),
                      sourceWorkspace.bonsplitController.splitPane(
                        resolvedTargetPane,
                        orientation: splitTarget.orientation,
                        movingTab: sourceTabId,
                        insertFirst: splitTarget.insertFirst
                      ) != nil else {
#if DEBUG
                    cmuxDebugLog(
                        "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=sameWorkspaceSplitFailed " +
                        "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) split=\(splitLabel) " +
                        "elapsedMs=\(elapsedMs(since: moveStart))"
                    )
#endif
                    return false
                }
                if focus {
                    source.tabManager.focusTab(sourceWorkspace.id, surfaceId: panelId, suppressFlash: true)
                }
#if DEBUG
                cmuxDebugLog(
                    "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceSplit moved=1 " +
                    "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
                )
#endif
                return true
            }

            let moved = sourceWorkspace.moveSurface(
                panelId: panelId,
                toPane: resolvedTargetPane,
                atIndex: targetIndex,
                focus: focus
            )
#if DEBUG
            cmuxDebugLog(
                "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=sameWorkspaceMove moved=\(moved ? 1 : 0) " +
                "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
                "elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return moved
        }

        let sourcePane = sourceWorkspace.paneId(forPanelId: panelId)
        let sourceIndex = sourceWorkspace.indexInPane(forPanelId: panelId)
#if DEBUG
        let detachStart = ProcessInfo.processInfo.systemUptime
#endif

        guard let detached = sourceWorkspace.detachSurface(panelId: panelId) else {
#if DEBUG
            cmuxDebugLog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=detachFailed " +
                "elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        let detachMs = elapsedMs(since: detachStart)
        let attachStart = ProcessInfo.processInfo.systemUptime
#endif
        guard destinationWorkspace.attachDetachedSurface(
            detached,
            inPane: resolvedTargetPane,
            atIndex: targetIndex,
            focus: focus
        ) != nil else {
            rollbackDetachedSurface(
                detached,
                to: sourceWorkspace,
                sourcePane: sourcePane,
                sourceIndex: sourceIndex,
                focus: focus
            )
#if DEBUG
            cmuxDebugLog(
                "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=attachFailed " +
                "detachMs=\(detachMs) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        let attachMs = elapsedMs(since: attachStart)
        var splitMs = "0.00"
#endif

        if let splitTarget {
#if DEBUG
            let splitStart = ProcessInfo.processInfo.systemUptime
#endif
            guard let movedTabId = destinationWorkspace.surfaceIdFromPanelId(panelId),
                  destinationWorkspace.bonsplitController.splitPane(
                    resolvedTargetPane,
                    orientation: splitTarget.orientation,
                    movingTab: movedTabId,
                    insertFirst: splitTarget.insertFirst
                  ) != nil else {
                if let detachedFromDestination = destinationWorkspace.detachSurface(panelId: panelId) {
                    rollbackDetachedSurface(
                        detachedFromDestination,
                        to: sourceWorkspace,
                        sourcePane: sourcePane,
                        sourceIndex: sourceIndex,
                        focus: focus
                    )
                }
#if DEBUG
                cmuxDebugLog(
                    "surface.move.fail panel=\(panelId.uuidString.prefix(5)) reason=postAttachSplitFailed " +
                    "detachMs=\(detachMs) attachMs=\(attachMs) elapsedMs=\(elapsedMs(since: moveStart))"
                )
#endif
                return false
            }
#if DEBUG
            splitMs = elapsedMs(since: splitStart)
#endif
        }

#if DEBUG
        let cleanupStart = ProcessInfo.processInfo.systemUptime
#endif
        cleanupEmptySourceWorkspaceAfterSurfaceMove(
            sourceWorkspace: sourceWorkspace,
            sourceManager: source.tabManager,
            sourceWindowId: source.windowId
        )
#if DEBUG
        let cleanupMs = elapsedMs(since: cleanupStart)
        let focusStart = ProcessInfo.processInfo.systemUptime
#endif

        if focus {
            let destinationWindowId = focusWindow ? windowId(for: destinationManager) : nil
            if let destinationWindowId {
                _ = focusMainWindow(windowId: destinationWindowId)
            }
            destinationManager.focusTab(targetWorkspaceId, surfaceId: panelId, suppressFlash: true)
            if let destinationWindowId {
                reassertCrossWindowSurfaceMoveFocusIfNeeded(
                    destinationWindowId: destinationWindowId,
                    sourceWindowId: source.windowId,
                    destinationWorkspaceId: targetWorkspaceId,
                    destinationPanelId: panelId,
                    destinationManager: destinationManager
                )
            }
        }
#if DEBUG
        let focusMs = elapsedMs(since: focusStart)
        cmuxDebugLog(
            "surface.move.end panel=\(panelId.uuidString.prefix(5)) path=crossWorkspace moved=1 " +
            "sourceWs=\(sourceWorkspace.id.uuidString.prefix(5)) destinationWs=\(destinationWorkspace.id.uuidString.prefix(5)) " +
            "targetPane=\(resolvedTargetPane.id.uuidString.prefix(5)) targetIndex=\(targetIndex.map(String.init) ?? "nil") " +
            "split=\(splitLabel) detachMs=\(detachMs) attachMs=\(attachMs) splitMs=\(splitMs) " +
            "cleanupMs=\(cleanupMs) focusMs=\(focusMs) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif

        return true
    }

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
#if DEBUG
        let moveStart = ProcessInfo.processInfo.systemUptime
        func elapsedMs(since start: TimeInterval) -> String {
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return String(format: "%.2f", ms)
        }
        cmuxDebugLog(
            "surface.moveBonsplit.begin tab=\(tabId.uuidString.prefix(5)) targetWs=\(targetWorkspaceId.uuidString.prefix(5)) " +
            "targetPane=\(targetPane?.id.uuidString.prefix(5) ?? "auto") targetIndex=\(targetIndex.map(String.init) ?? "nil")"
        )
#endif
        guard let located = locateBonsplitSurface(tabId: tabId) else {
            // The tab isn't in any workspace pane tree — it may be a Dock tab
            // being dragged out into the main split area. Route the live panel
            // out of its Dock and into the destination workspace.
            if let dockSource = locateDockSurface(tabId: tabId) {
                return moveDockSurfaceToWorkspace(
                    sourceDock: dockSource.dock,
                    panelId: dockSource.panelId,
                    toWorkspace: targetWorkspaceId,
                    targetPane: targetPane,
                    targetIndex: targetIndex,
                    splitTarget: splitTarget,
                    focus: focus,
                    focusWindow: focusWindow
                )
            }
#if DEBUG
            cmuxDebugLog(
                "surface.moveBonsplit.fail tab=\(tabId.uuidString.prefix(5)) reason=tabNotFound " +
                "targetWs=\(targetWorkspaceId.uuidString.prefix(5)) elapsedMs=\(elapsedMs(since: moveStart))"
            )
#endif
            return false
        }
#if DEBUG
        cmuxDebugLog(
            "surface.moveBonsplit.located tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "sourceWs=\(located.workspaceId.uuidString.prefix(5)) sourceWin=\(located.windowId.uuidString.prefix(5))"
        )
#endif
        let moved = moveSurface(
            panelId: located.panelId,
            toWorkspace: targetWorkspaceId,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: focus,
            focusWindow: focusWindow
        )
#if DEBUG
        cmuxDebugLog(
            "surface.moveBonsplit.end tab=\(tabId.uuidString.prefix(5)) panel=\(located.panelId.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(elapsedMs(since: moveStart))"
        )
#endif
        return moved
    }

    @discardableResult
    func focusScriptableMainWindow(windowId: UUID, bringToFront shouldBringToFront: Bool) -> Bool {
        guard let state = scriptableMainWindow(windowId: windowId),
              let window = state.window else {
            return false
        }
        setActiveMainWindow(window)
        if shouldBringToFront {
            bringToFront(window)
        }
        return true
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
        commandPaletteWindowStore.markOpenRequested(windowId, now: ProcessInfo.processInfo.systemUptime)
    }

    private func postCommandPaletteRequest(
        kind: CommandPaletteRequestKind,
        preferredWindow: NSWindow?,
        source: String
    ) {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        if let targetWindow,
           let context = contextForMainWindow(targetWindow) {
            _ = context.tabManager.setFocusedBrowserFocusModeActive(false, reason: "commandPaletteRequest.\(source)")
        }
        let markPending = kind.marksPending
        if markPending {
            markCommandPaletteOpenRequested(for: targetWindow)
        }
        NotificationCenter.default.post(name: Notification.Name(kind.notificationName), object: targetWindow)
#if DEBUG
        cmuxDebugLog(
            "shortcut.palette.request source=\(source) " +
            "target={\(debugWindowToken(targetWindow))} " +
            "pendingMarked=\(markPending ? 1 : 0)"
        )
#endif
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
        commandPaletteWindowStore.clearPendingOpen(windowId)
    }

    private func pruneExpiredCommandPalettePendingOpenStates(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let pruned = commandPaletteWindowStore.pruneExpiredPendingOpenStates(now: now)
#if DEBUG
        for outcome in pruned {
            switch outcome {
            case .missingTimestamp(let windowId):
                cmuxDebugLog("shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) reason=missingTimestamp")
            case .stale(let windowId, let age):
                cmuxDebugLog(
                    "shortcut.palette.pendingPrune windowId=\(windowId.uuidString.prefix(8)) " +
                    "reason=stale ageMs=\(Int(age * 1000))"
                )
            }
        }
#else
        _ = pruned
#endif
    }

    private func isCommandPalettePendingOpen(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        pruneExpiredCommandPalettePendingOpenStates()
        return commandPaletteWindowStore.isPendingOpenRaw(windowId)
    }

    private func beginCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPaletteWindowStore.beginEscapeSuppression(windowId, now: ProcessInfo.processInfo.systemUptime)
    }

    private func endCommandPaletteEscapeSuppression(for window: NSWindow?) {
        guard let window,
              let windowId = mainWindowId(for: window) else { return }
        commandPaletteWindowStore.endEscapeSuppression(windowId)
    }

    private func shouldConsumeSuppressedEscape(event: NSEvent, window: NSWindow?) -> Bool {
        guard let window,
              let windowId = mainWindowId(for: window) else {
            return false
        }
        return commandPaletteWindowStore.shouldConsumeSuppressedEscape(
            windowId,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func recentCommandPaletteRequestAge(for window: NSWindow?) -> TimeInterval? {
        guard let window,
              let windowId = mainWindowId(for: window) else {
            return nil
        }
        return commandPaletteWindowStore.recentRequestAge(
            windowId,
            now: ProcessInfo.processInfo.systemUptime
        )
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
        commandPaletteWindowStore.clearAllEscapeSuppression()
#if DEBUG
        cmuxDebugLog("shortcut.escape suppressionClear target={nil} clearedAll=1 keyUpConsumed=\(didConsume ? 1 : 0)")
#endif
        return didConsume
    }

    func setCommandPaletteVisible(_ visible: Bool, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        if visible, let context = contextForMainWindow(window) {
            _ = context.tabManager.setFocusedBrowserFocusModeActive(false, reason: "commandPaletteVisible")
        }
        // Opening (false -> true) always resolves pending-open.
        // Closing (true -> false) also clears stale pending state.
        // Ignore repeated false updates so a stale sync cannot erase an in-flight open request.
        let update = commandPaletteWindowStore.setVisible(visible, for: windowId)
        postCommandPaletteVisibilityDidChangeIfNeeded(wasVisible: update.wasVisible, visible: visible, window: window, windowId: windowId)
#if DEBUG
        if update.retainedPending {
            cmuxDebugLog(
                "palette.visibility.retainPending " +
                "window={\(debugWindowToken(window))} visible=0 wasVisible=0 pending=1"
            )
        }
#endif
    }

    func isCommandPaletteVisible(windowId: UUID) -> Bool {
        commandPaletteWindowStore.isVisible(windowId)
    }

    func setCommandPaletteSelectionIndex(_ index: Int, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteWindowStore.setSelectionIndex(index, for: windowId)
    }

    func commandPaletteSelectionIndex(windowId: UUID) -> Int {
        commandPaletteWindowStore.selectionIndex(windowId)
    }

    func setCommandPaletteSnapshot(_ snapshot: CommandPaletteDebugSnapshot, for window: NSWindow) {
        guard let windowId = mainWindowId(for: window) else { return }
        commandPaletteWindowStore.setSnapshot(snapshot, for: windowId)
    }

    func commandPaletteSnapshot(windowId: UUID) -> CommandPaletteDebugSnapshot {
        commandPaletteWindowStore.snapshot(windowId)
    }

    func isCommandPaletteVisible(for window: NSWindow) -> Bool {
        guard let windowId = mainWindowId(for: window) else { return false }
        return commandPaletteWindowStore.isVisible(windowId)
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
                return isInsideCommandPaletteOverlay(delegateView)
            }
            // SwiftUI can attach a non-view delegate to TextField editors.
            // When command palette is visible, its search/rename editor is the
            // only expected field editor inside the main window.
            return true
        }
        if let view = responder as? NSView {
            return isInsideCommandPaletteOverlay(view)
        }
        return false
    }

    private func isFocusStealingResponderWhileCommandPaletteVisible(_ responder: NSResponder) -> Bool {
        responder.isCommandPaletteFocusStealingTerminalOrBrowser
    }

    private func isInsideCommandPaletteOverlay(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return true
            }
            current = candidate.superview
        }
        return false
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

    func locateSurface(surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        for ctx in mainWindowContexts.values {
            for ws in ctx.tabManager.tabs {
                if ws.panels[surfaceId] != nil, ws.surfaceIdFromPanelId(surfaceId) != nil {
                    return (ctx.windowId, ws.id, ctx.tabManager)
                }
            }
        }
        for route in recoverableMainWindowRoutes() {
            guard let manager = route.tabManager else { continue }
            for ws in manager.tabs {
                if ws.panels[surfaceId] != nil, ws.surfaceIdFromPanelId(surfaceId) != nil {
                    return (route.windowId, ws.id, manager)
                }
            }
        }
        return nil
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

        if let located = locateSurface(surfaceId: panelId),
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
        for ctx in mainWindowContexts.values {
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
        for context in mainWindowContexts.values {
            visitManager(context.tabManager)
        }
    }

    func focusMainWindow(windowId: UUID) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        let didFocus = mainWindowVisibilityController.focus(window, reason: .focusMainWindow)
        if didFocus {
            publishCmuxWindowLifecycle(name: "window.focused", windowId: windowId, origin: "focus_request")
        }
        return didFocus
    }

    func closeMainWindow(windowId: UUID, recordHistory: Bool = true) -> Bool {
        guard let window = windowForMainWindowId(windowId) else { return false }
        if !recordHistory {
            closedWindowHistorySuppressedWindowIds.insert(windowId)
        }
        window.performClose(nil)
        return true
    }

    func discardMainWindowWithoutClosedHistory(windowId: UUID) {
        guard let window = windowForMainWindowId(windowId) else { return }
        closedWindowHistorySuppressedWindowIds.insert(windowId)
        window.close()
    }

    private func confirmCloseMainWindow(_ window: NSWindow) -> Bool {
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

    @discardableResult
    func closeWindowWithConfirmation(_ window: NSWindow) -> Bool {
        guard isMainTerminalWindow(window) else {
            window.performClose(nil)
            return true
        }
        guard confirmCloseMainWindow(window) else { return true }
        window.performClose(nil)
        return true
    }

    private func orderedMainWindowSummaries(referenceWindowId: UUID?) -> [MainWindowSummary] {
        let summaries = listMainWindowSummaries()
        return summaries.sorted { lhs, rhs in
            let lhsIsReference = lhs.windowId == referenceWindowId
            let rhsIsReference = rhs.windowId == referenceWindowId
            if lhsIsReference != rhsIsReference { return lhsIsReference }
            if lhs.isKeyWindow != rhs.isKeyWindow { return lhs.isKeyWindow }
            if lhs.isVisible != rhs.isVisible { return lhs.isVisible }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    private func windowLabelsById(orderedSummaries: [MainWindowSummary], referenceWindowId: UUID?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        for (index, summary) in orderedSummaries.enumerated() {
            if summary.windowId == referenceWindowId {
                labels[summary.windowId] = String(localized: "menu.currentWindow", defaultValue: "Current Window")
            } else {
                let number = index + 1
                labels[summary.windowId] = String(localized: "menu.windowNumber", defaultValue: "Window \(number)")
            }
        }
        return labels
    }

    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace") : trimmed
    }

    func rollbackDetachedSurface(
        _ detached: Workspace.DetachedSurfaceTransfer,
        to workspace: Workspace,
        sourcePane: PaneID?,
        sourceIndex: Int?,
        focus: Bool
    ) {
        let rollbackPane = sourcePane.flatMap { pane in
            workspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
        } ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let rollbackPane else { return }
        _ = workspace.attachDetachedSurface(
            detached,
            inPane: rollbackPane,
            atIndex: sourceIndex,
            focus: focus
        )
    }

    func cleanupEmptySourceWorkspaceAfterSurfaceMove(
        sourceWorkspace: Workspace,
        sourceManager: TabManager,
        sourceWindowId: UUID
    ) {
        guard sourceWorkspace.panels.isEmpty else { return }
        guard sourceManager.tabs.contains(where: { $0.id == sourceWorkspace.id }) else { return }

        if sourceManager.tabs.count > 1 {
            sourceManager.closeWorkspace(sourceWorkspace, recordHistory: false)
        } else {
            _ = closeMainWindow(windowId: sourceWindowId, recordHistory: false)
        }
    }

    func reassertCrossWindowSurfaceMoveFocusIfNeeded(
        destinationWindowId: UUID,
        sourceWindowId: UUID,
        destinationWorkspaceId: UUID,
        destinationPanelId: UUID,
        destinationManager: TabManager
    ) {
        let reassert: () -> Void = { [weak self, weak destinationManager] in
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: reassert)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: reassert)
    }

    func resolvedWindow(for context: MainWindowContext) -> NSWindow? {
        if let window = context.window {
            return window
        }
        guard let window = windowForMainWindowId(context.windowId) else {
            return nil
        }
        reindexMainWindowContextIfNeeded(context, for: window)
        return window
    }

    func mainWindowId(from window: NSWindow) -> UUID? {
        guard let raw = window.identifier?.rawValue else { return nil }
        let prefix = "cmux.main."
        guard raw.hasPrefix(prefix) else { return nil }
        let suffix = String(raw.dropFirst(prefix.count))
        return UUID(uuidString: suffix)
    }

    private func reindexMainWindowContextIfNeeded(_ context: MainWindowContext, for window: NSWindow) {
        let desiredKey = ObjectIdentifier(window)
        if mainWindowContexts[desiredKey] === context {
            context.window = window
            return
        }

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }

        if let conflicting = mainWindowContexts[desiredKey], conflicting !== context {
            context.window = window
            return
        }

        mainWindowContexts[desiredKey] = context
        context.window = window
        notifyMainWindowContextsDidChange()
    }

    func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> MainWindowContext? {
        guard isMainTerminalWindow(window) else { return nil }

        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            context.window = window
            return context
        }

        if let windowId = mainWindowId(from: window),
           let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        let windowNumber = window.windowNumber
        if windowNumber >= 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let candidateWindow = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return candidateWindow?.windowNumber == windowNumber
           }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        return nil
    }

    private func unregisterMainWindowContext(for window: NSWindow) -> MainWindowContext? {
        guard let removed = contextForMainTerminalWindow(window, reindex: false) else { return nil }
        removed.teardownWindowDock()
        let removedKeys = mainWindowContexts.compactMap { key, value in
            value === removed ? key : nil
        }
        for key in removedKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        rememberRecoverableMainWindowRoute(windowId: removed.windowId, tabManager: removed.tabManager, window: removed.window)
        removeMobileWorkspaceListObserverIfUnused(for: removed.tabManager)
        notifyMainWindowContextsDidChange()
        return removed
    }

    // Internal (not private): see notifyMainWindowContextsDidChange.
    func discardOrphanedMainWindowContext(_ context: MainWindowContext, allowWindowlessFallback: Bool = false) {
        context.teardownWindowDock()
        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        rememberRecoverableMainWindowRoute(windowId: context.windowId, tabManager: context.tabManager, window: context.window)
        removeMobileWorkspaceListObserverIfUnused(for: context.tabManager)
        notifyMainWindowContextsDidChange()

        commandPaletteWindowStore.removeWindow(context.windowId)

        if tabManager === context.tabManager {
            activateMainWindowContext(Array(mainWindowContexts.values).first { resolvedWindow(for: $0) != nil } ?? (allowWindowlessFallback ? mainWindowContexts.values.first : nil))
        }

        if let store = notificationStore {
            store.clearNotifications(forTabId: context.windowId)
            for tab in context.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }
    }

    private func pruneWindowlessMainWindowContexts() {
        for context in Array(mainWindowContexts.values) where resolvedWindow(for: context) == nil {
            discardOrphanedMainWindowContext(context)
        }
    }

    private func mainWindowId(for window: NSWindow) -> UUID? {
        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            return context.windowId
        }
        guard let rawIdentifier = window.identifier?.rawValue,
              rawIdentifier.hasPrefix("cmux.main.") else { return nil }
        let idPart = String(rawIdentifier.dropFirst("cmux.main.".count))
        return UUID(uuidString: idPart)
    }

    private func commandPaletteOverlayContainer(in window: NSWindow) -> NSView? {
        guard let searchRoot = window.contentView?.superview ?? window.contentView else { return nil }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    private func isCommandPaletteOverlayPresented(in window: NSWindow) -> Bool {
        guard let container = commandPaletteOverlayContainer(in: window) else { return false }
        return !container.isHidden && container.alphaValue > 0.001
    }

    private func isCommandPaletteResponderActive(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let textView = responder as? NSTextView,
           textView.isFieldEditor,
           !(textView.delegate is NSView) {
            // Field-editor delegates can be non-view responders. Confirm the overlay is
            // mounted and visible to avoid treating unrelated editors as palette input.
            return isCommandPaletteOverlayPresented(in: window)
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
            || isCommandPaletteOverlayPresented(in: window)
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
        if let visibleWindowId = commandPaletteWindowStore.firstVisibleWindowId() {
            return windowForMainWindowId(visibleWindowId)
        }
        if let pendingWindowId = commandPaletteWindowStore.firstPendingOpenWindowId() {
            return windowForMainWindowId(pendingWindowId)
        }
        return nil
    }

    func commandPaletteWindowForShortcutEvent(_ event: NSEvent) -> NSWindow? {
        if let scopedWindow = mainWindowForShortcutEvent(event) {
            return scopedWindow
        }
        return activeCommandPaletteWindow()
    }

    /// Opens the diff viewer for the focused workspace of `tabManager` by spawning the
    /// bundled `cmux diff` CLI. This is the single shared diff-open path: both the
    /// command-palette entries and the Open Diff Viewer keyboard shortcut funnel through
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
        let socketPath = TerminalController.shared.activeSocketPath(
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
            let originWindowId = tabManager.flatMap { manager in
                mainWindowContexts.values.first { $0.tabManager === manager }?.windowId
            }
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
            sessionId: agentDiffContext?.sessionId
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
        let process = Process()
        process.executableURL = cliURL
        var arguments = [
            "--socket", socketPath,
            "diff",
            useLastTurnSource ? "--last-turn" : "--unstaged",
            "--cwd", cwd,
            "--workspace", workspaceId.uuidString,
            "--focus", focus ? "true" : "false",
        ]
        if let surfaceId {
            arguments.append(contentsOf: ["--surface", surfaceId.uuidString])
        }
        if useLastTurnSource, let sessionId {
            arguments.append(contentsOf: ["--session", sessionId])
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment["CMUX_WORKSPACE_ID"] = workspaceId.uuidString
        if let surfaceId {
            environment["CMUX_SURFACE_ID"] = surfaceId.uuidString
        }
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let outputCollector = ProcessOutputCollector(stdout: stdoutPipe, stderr: stderrPipe)
        outputCollector.start()
        process.terminationHandler = { terminatedProcess in
            let output = outputCollector.finish()
            let processIdentifier = terminatedProcess.processIdentifier
            let terminationStatus = terminatedProcess.terminationStatus
            Task { @MainActor in
                AppDelegate.shared?.diffViewerProcesses.removeValue(forKey: processIdentifier)
                guard terminationStatus != 0 else { return }
#if DEBUG
                // Log only non-sensitive metadata: the child's stdout/stderr can echo
                // repo paths and file contents, so report a byte count, not the text.
                cmuxDebugLog("openDiffViewer exited status=\(terminationStatus) outputBytes=\(output.utf8.count)")
#endif
                NSSound.beep()
            }
        }

        do {
            try process.run()
            let processIdentifier = process.processIdentifier
            diffViewerProcesses[processIdentifier] = process
            if !process.isRunning {
                diffViewerProcesses.removeValue(forKey: processIdentifier)
            }
#if DEBUG
            cmuxDebugLog("openDiffViewer pid=\(process.processIdentifier)")
#endif
            return true
        } catch {
            outputCollector.cancel()
#if DEBUG
            cmuxDebugLog("openDiffViewer failed errorType=\(type(of: error))")
#endif
            return false
        }
    }

    func allMainWindowTabManagersForDebug() -> [TabManager] {
        Array(mainWindowContexts.values).compactMap { context in
            resolvedWindow(for: context) == nil ? nil : context.tabManager
        }
    }
#if DEBUG
    private func debugManagerToken(_ manager: TabManager?) -> String {
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

    private func debugContextToken(_ context: MainWindowContext?) -> String {
        guard let context else { return "nil" }
        let selected = context.tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let hasWindow = (context.window != nil || windowForMainWindowId(context.windowId) != nil) ? 1 : 0
        return "id=\(String(context.windowId.uuidString.prefix(8))) mgr=\(debugManagerToken(context.tabManager)) tabs=\(context.tabManager.tabs.count) selected=\(selected) hasWindow=\(hasWindow)"
    }

    private func debugShortcutRouteSnapshot(event: NSEvent? = nil) -> String {
        let activeManager = tabManager
        let activeWindowId = activeManager.flatMap { windowId(for: $0) }.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let selectedWorkspace = activeManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"

        let contexts = mainWindowContexts.values
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
        .first { cmuxWindowShouldOwnCloseShortcut($0) }
    }

    /// Re-sync app-level active window pointers from the currently focused main terminal window.
    /// This keeps menu/shortcut actions window-scoped even if the cached `tabManager` drifts.
    @discardableResult
    func synchronizeActiveMainWindowContext(preferredWindow: NSWindow? = nil) -> TabManager? {
        let (context, source): (MainWindowContext?, String) = {
            if let preferredWindow,
               let context = contextForMainWindow(preferredWindow) {
                return (context, "preferredWindow")
            }
            if let context = contextForMainWindow(shortcutRoutingKeyWindow) {
                return (context, "keyWindow")
            }
            if let context = contextForMainWindow(NSApp.mainWindow) {
                return (context, "mainWindow")
            }
            if let activeManager = tabManager,
               let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
                return (activeContext, "activeManager")
            }
            return (mainWindowContexts.values.first, "firstContextFallback")
        }()

#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
        cmuxDebugLog(
            "shortcut.sync.pre source=\(source) preferred={\(debugWindowToken(preferredWindow))} chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        guard let context else { return tabManager }
        let alreadyActive =
            tabManager === context.tabManager
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive {
#if DEBUG
            cmuxDebugLog(
                "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} nochange=1 \(debugShortcutRouteSnapshot())"
            )
#endif
            return context.tabManager
        }
        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            fileExplorerState = context.fileExplorerState
            TerminalController.shared.setActiveTabManager(context.tabManager)
        }
#if DEBUG
        cmuxDebugLog(
            "shortcut.sync.post source=\(source) beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) chosen={\(debugContextToken(context))} \(debugShortcutRouteSnapshot())"
        )
#endif
        return context.tabManager
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

    private func preferredMainWindowContextForShortcuts(event: NSEvent) -> MainWindowContext? {
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
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    func preferredRegisteredMainWindowContext(preferredWindow: NSWindow? = nil) -> MainWindowContext? {
        if let preferredWindow,
           let context = contextForMainWindow(preferredWindow) {
            return context
        }
        if let context = contextForMainWindow(shortcutRoutingKeyWindow) {
            return context
        }
        if let context = contextForMainWindow(NSApp.mainWindow) {
            return context
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return activeContext
        }
        return mainWindowContexts.values.first
    }

    private func activateMainWindowContextForShortcutEvent(_ event: NSEvent) {
        let preferredWindow = mainWindowForShortcutEvent(event)
#if DEBUG
        cmuxDebugLog(
            "shortcut.activate.pre event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        _ = synchronizeActiveMainWindowContext(preferredWindow: preferredWindow)
#if DEBUG
        cmuxDebugLog(
            "shortcut.activate.post event=\(NSWindow.keyDescription(event)) preferred={\(debugWindowToken(preferredWindow))} \(debugShortcutRouteSnapshot(event: event))"
        )
#endif
    }

    @discardableResult
    func toggleSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        func toggle(_ context: MainWindowContext) -> Bool {
            guard let window = resolvedWindow(for: context) else {
                discardOrphanedMainWindowContext(context)
                return false
            }
            setActiveMainWindow(window)
            context.sidebarState.toggle()
            return true
        }

        if let preferredWindow,
           let preferredContext = contextForMainTerminalWindow(preferredWindow),
           toggle(preferredContext) {
            return true
        }
        if let keyWindow = shortcutRoutingKeyWindow,
           let keyContext = contextForMainTerminalWindow(keyWindow),
           toggle(keyContext) {
            return true
        }
        if let mainWindow = NSApp.mainWindow,
           let mainContext = contextForMainTerminalWindow(mainWindow),
           toggle(mainContext) {
            return true
        }
        if let activeManager = tabManager,
           let activeContext = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }),
           toggle(activeContext) {
            return true
        }
        for fallbackContext in Array(mainWindowContexts.values) where toggle(fallbackContext) {
            return true
        }
        return false
    }

    @discardableResult
    func toggleRightSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            if let fileExplorerState {
                fileExplorerState.toggle()
                return true
            }
            return false
        }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            setActiveMainWindow(window)
        }

        guard let state = context.fileExplorerState ?? fileExplorerState else {
            return false
        }
        let wasVisible = state.isVisible
        state.toggle()
        if wasVisible && !state.isVisible {
            _ = context.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded()
        }
        return true
    }

    func applyRightSidebarRemoteCommand(
        _ command: RightSidebarRemoteCommand,
        target: RightSidebarRemoteTarget = RightSidebarRemoteTarget()
    ) -> RightSidebarRemoteApplyResult {
        let context = rightSidebarRemoteContext(target: target)
        if !target.isActiveTarget, context == nil {
            return .failure(String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"))
        }
        let state: FileExplorerState?
        if target.isActiveTarget {
            state = context?.fileExplorerState ?? fileExplorerState
        } else {
            state = context?.fileExplorerState
        }
        guard let state else {
            return .failure(String(localized: "rightSidebar.remote.error.stateUnavailable", defaultValue: "ERROR: Right sidebar state not available"))
        }

        let preferredWindow = context.flatMap { $0.window ?? windowForMainWindowId($0.windowId) }
        let requiresWindowFocus: Bool
        switch command {
        case .focus:
            requiresWindowFocus = true
        case .setMode(_, let focus):
            requiresWindowFocus = focus
        case .toggle, .show, .hide, .getState:
            requiresWindowFocus = false
        }
        if requiresWindowFocus, !target.isActiveTarget, preferredWindow == nil {
            return .failure(String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"))
        }

        switch command {
        case .toggle:
            guard target.isActiveTarget || preferredWindow != nil else {
                return .failure(String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"))
            }
            guard toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow) else {
                return .failure(String(localized: "rightSidebar.remote.error.unavailable", defaultValue: "ERROR: Right sidebar not available"))
            }
            return .ok

        case .show:
            guard !state.isVisible else {
                return .ok
            }
            guard target.isActiveTarget || preferredWindow != nil else {
                return .failure(String(localized: "rightSidebar.remote.error.targetNotFound", defaultValue: "ERROR: Right sidebar target not found"))
            }
            guard toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow) else {
                return .failure(String(localized: "rightSidebar.remote.error.unavailable", defaultValue: "ERROR: Right sidebar not available"))
            }
            return .ok

        case .hide:
            let wasVisible = state.isVisible
            state.setVisible(false)
            if wasVisible {
                _ = context?.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded()
            }
            return .ok

        case .focus:
            // Remote focus should preserve the currently selected sidebar mode
            // instead of reviving a stale keyboard-focus memory.
            guard focusRightSidebarInActiveMainWindow(mode: state.mode, preferredWindow: preferredWindow) else {
                return .failure(String(localized: "rightSidebar.remote.error.focusFailed", defaultValue: "ERROR: Failed to focus right sidebar"))
            }
            return .ok

        case .setMode(let mode, let focus):
            guard mode.isAvailable() else {
                return .failure(String(localized: "rightSidebar.remote.error.modeUnavailable", defaultValue: "ERROR: Right sidebar mode '\(mode.rawValue)' is not available"))
            }
            if focus {
                guard focusRightSidebarInActiveMainWindow(mode: mode, focusFirstItem: true, preferredWindow: preferredWindow) else {
                    return .failure(String(localized: "rightSidebar.remote.error.focusFailed", defaultValue: "ERROR: Failed to focus right sidebar"))
                }
            } else {
                state.setVisible(true)
                state.mode = mode
                context?.keyboardFocusCoordinator.rememberRightSidebarMode(mode)
            }
            return .ok
        case .getState:
            return .state(.init(visible: state.isVisible, modeRawValue: state.rightSidebarRemoteModeRawValue))
        }
    }

    private func rightSidebarRemoteContext(target: RightSidebarRemoteTarget) -> MainWindowContext? {
        if let windowId = target.windowId {
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }
        if let workspaceId = target.workspaceId {
            return mainWindowContexts.values.first { context in
                context.tabManager.tabs.contains(where: { $0.id == workspaceId })
            }
        }
        return preferredRegisteredMainWindowContext()
    }

    @discardableResult
    func closeRightSidebarInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else {
            guard let fileExplorerState else {
                return false
            }
            fileExplorerState.setVisible(false)
            return true
        }

        let window = context.window ?? windowForMainWindowId(context.windowId)
        if let window {
            setActiveMainWindow(window)
        }

        guard let state = context.fileExplorerState ?? fileExplorerState else {
            return false
        }
        let wasVisible = state.isVisible
        state.setVisible(false)
        if wasVisible && !state.isVisible {
            _ = context.keyboardFocusCoordinator.restoreTerminalFocusAfterRightSidebarHiddenIfNeeded()
        }
        return true
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
        guard let window else { return false }
        let sidebarIntentActive = keyboardFocusCoordinator(for: window)?.activeRightSidebarMode != nil
        guard let responder = window.firstResponder else { return sidebarIntentActive }
        if isRightSidebarFocusResponder(responder, in: window) { return true }
        if terminalKeyboardFocusRequest(for: responder) != nil { return false }
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let panelId = ghosttyView.terminalSurface?.id else { return false }
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
        for context in mainWindowContexts.values {
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
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "rs.focus.app.abort reason=noContext preferred={\(debugWindowToken(preferredWindow))} " +
                "\(debugShortcutRouteSnapshot())"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let beforeState = context.fileExplorerState ?? fileExplorerState
        dlog(
            "rs.focus.app.begin preferred={\(debugWindowToken(preferredWindow))} " +
            "context={\(debugContextToken(context))} targetWin={\(debugWindowToken(window))} " +
            "visible=\((beforeState?.isVisible ?? false) ? 1 : 0) mode=\(beforeState?.mode.rawValue ?? "nil") " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .rightSidebarFocus)
        }
        let result = context.keyboardFocusCoordinator.focusRightSidebar(
            mode: requestedMode,
            focusFirstItem: focusFirstItem
        )
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.app.end requested=1 result=\(result ? 1 : 0) " +
            "mode=\(requestedMode?.rawValue ?? (context.fileExplorerState?.mode.rawValue ?? "nil")) " +
            "targetWin={\(debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
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
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)
        let window = context.flatMap { $0.window ?? windowForMainWindowId($0.windowId) }
        if let window {
            if !window.isKeyWindow {
                if !NSApp.isActive {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                }
                window.makeKeyAndOrderFront(nil)
            }
            setActiveMainWindow(window)
        }

        guard let state = context?.fileExplorerState ?? fileExplorerState else {
            return (
                revealed: false,
                focusApplied: false,
                contextFound: context != nil,
                stateFound: false,
                visible: false,
                activeMode: nil
            )
        }

        if state.mode != mode {
            state.mode = mode
        }
        state.setVisible(true)

        let focusApplied = context?.keyboardFocusCoordinator.focusRightSidebar(
            mode: mode,
            focusFirstItem: focusFirstItem
        ) ?? false

        return (
            revealed: state.isVisible && state.mode == mode,
            focusApplied: focusApplied,
            contextFound: context != nil,
            stateFound: true,
            visible: state.isVisible,
            activeMode: state.mode.rawValue
        )
    }
#endif

    @discardableResult
    func focusFileSearchInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "file.search.focus.app.abort reason=noContext preferred={\(debugWindowToken(preferredWindow))} " +
                "\(debugShortcutRouteSnapshot())"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "file.search.focus.app.begin preferred={\(debugWindowToken(preferredWindow))} " +
            "context={\(debugContextToken(context))} targetWin={\(debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .fileSearchFocus)
        }
        let result = context.keyboardFocusCoordinator.focusFileSearch()
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "file.search.focus.app.end result=\(result ? 1 : 0) " +
            "targetWin={\(debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    @discardableResult
    func performFindShortcutInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "find.shortcut.app.abort reason=noContext preferred={\(debugWindowToken(preferredWindow))} " +
                "\(debugShortcutRouteSnapshot())"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "find.shortcut.app.begin preferred={\(debugWindowToken(preferredWindow))} " +
            "context={\(debugContextToken(context))} targetWin={\(debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        let target = context.keyboardFocusCoordinator.findShortcutTarget(
            currentResponder: window?.firstResponder
        )
        guard target != .none else {
#if DEBUG
            dlog(
                "find.shortcut.app.end target=\(target) result=0 " +
                "targetWin={\(debugWindowToken(window))} fr=\(beforeResponder)"
            )
#endif
            return false
        }

        if let window {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .findShortcut)
        }

        let result: Bool
        switch target {
        case .rightSidebarFileSearch:
            result = context.keyboardFocusCoordinator.focusFileSearch()
        case .mainPanelFind:
            result = context.tabManager.startSearch()
        case .none:
            return false
        }
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "find.shortcut.app.end target=\(target) result=\(result ? 1 : 0) " +
            "targetWin={\(debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    @discardableResult
    func toggleRightSidebarKeyboardFocusInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)

        guard let context else {
#if DEBUG
            dlog(
                "rs.focus.toggle.abort reason=noContext preferred={\(debugWindowToken(preferredWindow))} " +
                "\(debugShortcutRouteSnapshot())"
            )
#endif
            return false
        }
        let window = context.window ?? windowForMainWindowId(context.windowId)
#if DEBUG
        let beforeResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.toggle.begin preferred={\(debugWindowToken(preferredWindow))} " +
            "context={\(debugContextToken(context))} targetWin={\(debugWindowToken(window))} " +
            "fr=\(beforeResponder)"
        )
#endif
        if let window {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .rightSidebarToggle)
        }
        let result = context.keyboardFocusCoordinator.toggleRightSidebarOrTerminalFocus()
#if DEBUG
        let afterResponder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "rs.focus.toggle.end result=\(result ? 1 : 0) " +
            "targetWin={\(debugWindowToken(window))} fr=\(afterResponder)"
        )
#endif
        return result
    }

    func sidebarVisibility(windowId: UUID) -> Bool? {
        mainWindowContexts.values.first(where: { $0.windowId == windowId })?.sidebarState.isVisible
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "")
        let newWindowItem = NSMenuItem(
            title: String(localized: "menu.file.newWindow", defaultValue: "New Window"),
            action: #selector(openNewMainWindow(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)
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
            ?? mainWindowContexts.values.first(where: { $0.windowId == windowId })?.tabManager
            ?? preferredRegisteredMainWindowContext()?.tabManager
            ?? mainWindowContexts.values.first?.tabManager {
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

    private func hasVisibleMainTerminalWindow() -> Bool {
        mainWindowContexts.values.contains { context in
            guard let window = resolvedWindow(for: context) else { return false }
            return window.isVisible && !window.isMiniaturized && window.alphaValue > 0.001
        }
    }

    @discardableResult
    func performNewWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "newWorkspace"
    ) -> Bool {
        performNewWorkspaceCreationAction(
            initialSurface: .terminal,
            preferredTabManager: preferredTabManager,
            event: event,
            debugSource: debugSource
        )
    }

    /// Creates a new workspace whose initial surface is a browser pane in its
    /// default new-tab state with the address bar focused. Shares the window
    /// routing, placement, and naming semantics of `performNewWorkspaceAction`.
    @discardableResult
    func performNewBrowserWorkspaceAction(
        tabManager preferredTabManager: TabManager? = nil,
        event: NSEvent? = nil,
        debugSource: String = "newBrowserWorkspace"
    ) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled() else {
#if DEBUG
            cmuxDebugLog("newBrowserWorkspace.blocked_browser_disabled source=\(debugSource)")
#endif
            NSSound.beep()
            return false
        }
        return performNewWorkspaceCreationAction(
            initialSurface: .browser,
            preferredTabManager: preferredTabManager,
            event: event,
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
        var createdWorkspace: Workspace?
        let didCreate = performNewWorkspaceCreationAction(
            initialSurface: .browser,
            preferredTabManager: preferredTabManager,
            event: event,
            debugSource: debugSource,
            title: title,
            initialBrowserURL: url,
            initialBrowserOmnibarVisible: false,
            initialBrowserTransparentBackground: true,
            focusInitialBrowserAddressBarOnCreate: false,
            createdWorkspaceHandler: { workspace in
                createdWorkspace = workspace
            }
        )
        guard didCreate, let createdWorkspace else { return nil }
        focusInitialBrowserWebView(in: createdWorkspace)
        return createdWorkspace
    }

    func proUpgradeWorkspaceExists(workspaceId: UUID) -> Bool {
        mainWindowContexts.values.contains { context in
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

    private func performNewWorkspaceCreationAction(
        initialSurface: NewWorkspaceInitialSurface,
        preferredTabManager: TabManager?,
        event: NSEvent?,
        debugSource: String,
        title: String? = nil,
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false,
        focusInitialBrowserAddressBarOnCreate: Bool = true,
        createdWorkspaceHandler: ((Workspace) -> Void)? = nil
    ) -> Bool {
        let preferredContext = preferredTabManager.flatMap { mainWindowContext(for: $0) }
        let livePreferredContext: MainWindowContext? = {
            guard let preferredContext else { return nil }
            guard resolvedWindow(for: preferredContext) != nil else {
                discardOrphanedMainWindowContext(preferredContext)
                return nil
            }
            return preferredContext
        }()

        if mainWindowContexts.isEmpty && livePreferredContext == nil {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "fallback_new_window",
                source: debugSource,
                reason: "no_main_windows",
                event: event,
                chosenContext: nil
            )
#endif
            let windowId = createMainWindow()
            if let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
                let initialWorkspace = context.tabManager.selectedWorkspace
                switch initialSurface {
                case .terminal:
                    _ = executeConfiguredNewWorkspaceActionIfAvailable(
                        in: context,
                        debugSource: debugSource,
                        replacingInitialWorkspace: initialWorkspace
                    )
                case .browser:
                    // The fresh window boots with a terminal workspace; add the
                    // browser workspace and close that initial one so the
                    // action's result matches the no-window case for terminals.
                    let workspace = context.tabManager.addWorkspace(
                        title: title,
                        initialSurface: .browser,
                        initialBrowserURL: initialBrowserURL,
                        initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
                        initialBrowserTransparentBackground: initialBrowserTransparentBackground
                    )
                    closeInitialWorkspaceIfNeeded(
                        initialWorkspaceId: initialWorkspace?.id,
                        in: context
                    )
                    createdWorkspaceHandler?(workspace)
                    if focusInitialBrowserAddressBarOnCreate {
                        focusInitialBrowserAddressBar(in: workspace)
                    }
                case .cloudVMLoading:
                    let workspace = context.tabManager.addWorkspace(initialSurface: .cloudVMLoading)
                    closeInitialWorkspaceIfNeeded(
                        initialWorkspaceId: initialWorkspace?.id,
                        in: context
                    )
                    context.tabManager.setPinned(workspace, pinned: true)
                }
            }
            return true
        }

        let context = livePreferredContext
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)

        // In a dedicated remote-tmux window, a new workspace means "create a new
        // tmux session on that host" — route it to the remote and mirror it into
        // this window instead of creating a local workspace.
        if initialBrowserURL == nil,
           let context,
           remoteTmuxController.handleRemoteWindowNewWorkspaceRequested(windowId: context.windowId) {
            return true
        }

        let workspaceGroupTarget = context.flatMap { workspaceGroupNewWorkspaceTarget(in: $0) }
        // The configured new-workspace action is the user's override for the
        // plain New Workspace behavior; the browser variant keeps its own
        // fixed semantics and skips it.
        if initialSurface == .terminal,
           let context,
           executeConfiguredNewWorkspaceActionIfAvailable(
               in: context,
               debugSource: debugSource,
               workspaceGroupTarget: workspaceGroupTarget
           ) {
            return true
        }

        if let context, let workspaceGroupTarget {
            guard let workspace = context.tabManager.createWorkspaceInGroup(
                groupId: workspaceGroupTarget.groupId,
                placement: workspaceGroupTarget.placement,
                referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId,
                initialSurface: initialSurface,
                title: title,
                initialBrowserURL: initialBrowserURL,
                initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
                initialBrowserTransparentBackground: initialBrowserTransparentBackground
            ) else {
                return false
            }
            createdWorkspaceHandler?(workspace)
            if initialSurface == .browser, focusInitialBrowserAddressBarOnCreate {
                focusInitialBrowserAddressBar(in: workspace)
            }
            return true
        }

        if let preferredTabManager,
           preferredContext == nil || livePreferredContext != nil {
            let workspace = preferredTabManager.addWorkspace(
                title: title,
                initialSurface: initialSurface,
                initialBrowserURL: initialBrowserURL,
                initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
                initialBrowserTransparentBackground: initialBrowserTransparentBackground
            )
            createdWorkspaceHandler?(workspace)
            if initialSurface == .browser, focusInitialBrowserAddressBarOnCreate {
                focusInitialBrowserAddressBar(in: workspace)
            }
            return true
        }

        if let workspace = addWorkspaceInPreferredMainWindow(
            title: title,
            initialSurface: initialSurface,
            initialBrowserURL: initialBrowserURL,
            initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
            initialBrowserTransparentBackground: initialBrowserTransparentBackground,
            event: event,
            debugSource: debugSource
        ) {
            createdWorkspaceHandler?(workspace)
            if initialSurface == .browser, focusInitialBrowserAddressBarOnCreate {
                focusInitialBrowserAddressBar(in: workspace)
            }
        } else {
#if DEBUG
            logWorkspaceCreationRouting(
                phase: "fallback_new_window",
                source: debugSource,
                reason: "workspace_creation_returned_nil",
                event: event,
                chosenContext: nil
            )
#endif
            openNewMainWindow(nil)
        }
        return true
    }

    private func proUpgradeWorkspaceContext(workspaceId: UUID) -> (MainWindowContext, Workspace)? {
        for context in mainWindowContexts.values {
            if let workspace = context.tabManager.tabs.first(where: { $0.id == workspaceId }) {
                return (context, workspace)
            }
        }
        if let tabManager,
           let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
           let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) {
            return (context, workspace)
        }
        return nil
    }

    /// Routes first focus of a freshly created browser-initial workspace into
    /// the address bar so the user can type a URL immediately.
    private func focusInitialBrowserAddressBar(in workspace: Workspace) {
        guard let browserPanel = workspace.focusedSurfaceId.flatMap({ workspace.browserPanel(for: $0) })
            ?? workspace.panels.values.compactMap({ $0 as? BrowserPanel }).first else {
            return
        }
        workspace.focusPanel(browserPanel.id)
        focusBrowserAddressBar(in: browserPanel)
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
        onCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil
    ) -> Bool {
        let context = preferredTabManager.flatMap { mainWindowContext(for: $0) }
            ?? preferredWindow.flatMap { contextForMainWindow($0) }
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context else {
            NSSound.beep()
            return false
        }
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let workspaceTitle = String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM")
        let existingWorkspace = existingCloudVMWorkspace(in: context.tabManager)
        let workspace: Workspace
        if let existingWorkspace {
            workspace = existingWorkspace
            context.tabManager.selectedTabId = workspace.id
            context.tabManager.setPinned(workspace, pinned: true)
            if let loadingPanel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
                if !loadingPanel.hasFailed {
                    onCompletion?(CloudVMActionLauncher.Completion(terminationStatus: 0, output: "", workspaceId: workspace.id))
                    return true
                }
            } else {
                onCompletion?(CloudVMActionLauncher.Completion(terminationStatus: 0, output: "", workspaceId: workspace.id))
                return true
            }
        } else {
            workspace = context.tabManager.addWorkspace(
                title: workspaceTitle,
                initialSurface: .cloudVMLoading,
                inheritWorkingDirectory: false,
                select: true,
                autoWelcomeIfNeeded: false
            )
            context.tabManager.setPinned(workspace, pinned: true)
        }
        if let loadingPanel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
            loadingPanel.resetLoading()
        }
        let didStart = CloudVMActionLauncher.shared.start(
            socketPath: socketPath,
            preferredWindow: resolvedWindow(for: context) ?? preferredWindow,
            arguments: ["vm", "base", "open", "--workspace", workspace.id.uuidString],
            showsProgress: false,
            presentsFailureAlert: false,
            environmentOverrides: [
                "CMUX_CLOUD_ATTACH_RETRY_LIMIT": "12",
                "CMUX_CLOUD_ATTACH_RETRY_DELAY_SECONDS": "2",
            ],
            onCompletion: { completion in
                if !completion.succeeded,
                   let loadingPanel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
                    loadingPanel.showFailure(completion.output)
                }
                onCompletion?(completion)
            }
        )
        if !didStart,
           let loadingPanel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
            loadingPanel.showFailure(String(
                localized: "panel.cloudVM.loading.failed.launch",
                defaultValue: "Cloud VM command could not be launched."
            ))
        }
        return didStart
    }

    private func existingCloudVMWorkspace(in tabManager: TabManager) -> Workspace? {
        tabManager.tabs.first { workspace in
            if workspace.panels.values.contains(where: { $0.panelType == .cloudVMLoading }) {
                return true
            }
            guard let remote = workspace.remoteConfiguration else { return false }
            return remote.persistentDaemonSlot == "cmux-default-freestyle-sshd-v1" &&
                remote.managedCloudVMID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
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
        let socketPath = TerminalController.shared.activeSocketPath(
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
        let socketPath = TerminalController.shared.activeSocketPath(
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

    private func mainWindowContext(for tabManager: TabManager) -> MainWindowContext? {
        mainWindowContexts.values.first(where: { $0.tabManager === tabManager })
    }

    private func executeConfiguredNewWorkspaceActionIfAvailable(
        in context: MainWindowContext,
        debugSource: String,
        replacingInitialWorkspace initialWorkspace: Workspace? = nil,
        workspaceGroupTarget: WorkspaceGroupNewWorkspaceTarget? = nil
    ) -> Bool {
        guard let cmuxConfigStore = context.cmuxConfigStore,
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
        let initialWorkspaceId = initialWorkspace?.id
        if let workspaceGroupTarget,
           case .builtIn(.newWorkspace) = action.action {
            return context.tabManager.createWorkspaceInGroup(
                groupId: workspaceGroupTarget.groupId,
                placement: workspaceGroupTarget.placement,
                referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
            ) != nil
        }

        let beforeIds = workspaceGroupTarget.map { _ in Set(context.tabManager.tabs.map(\.id)) }
        var asyncObserverId: UUID?
        // Named workspace commands and inline workspace actions both create a
        // workspace, so both must retire the throwaway initial workspace.
        let actionCreatesWorkspace = action.workspaceCommandName != nil
            || action.action.inlineWorkspace != nil
        let onExecuted: (() -> Void)? = (!actionCreatesWorkspace && workspaceGroupTarget == nil) ? nil : { [weak self, weak context] in
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
                    asyncObserverId = ConfiguredGroupActionAsyncWorkspaceObserver.install(
                        tabManager: context.tabManager,
                        groupId: workspaceGroupTarget.groupId,
                        knownIds: Set(afterIds),
                        placement: workspaceGroupTarget.placement,
                        referenceWorkspaceId: workspaceGroupTarget.referenceWorkspaceId
                    )
                }
            }
            if actionCreatesWorkspace {
                self?.closeInitialWorkspaceIfNeeded(
                    initialWorkspaceId: initialWorkspaceId,
                    in: context
                )
            }
        }
        let onCloudVMCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = workspaceGroupTarget == nil ? nil : { [weak context] completion in
            guard let context, let asyncObserverId else { return }
            ConfiguredGroupActionAsyncWorkspaceObserver.finishPending(
                tabManager: context.tabManager,
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

    private func workspaceGroupNewWorkspaceTarget(in context: MainWindowContext) -> WorkspaceGroupNewWorkspaceTarget? {
        let tabManager = context.tabManager
        guard let selectedWorkspaceId = tabManager.selectedTabId,
              let selectedWorkspace = tabManager.tabs.first(where: { $0.id == selectedWorkspaceId }),
              let groupId = selectedWorkspace.groupId,
              let group = tabManager.workspaceGroups.first(where: { $0.id == groupId }) else {
            return nil
        }
        let anchorCwd = tabManager.tabs.first(where: { $0.id == group.anchorWorkspaceId })?.currentDirectory
        let configured = context.cmuxConfigStore?.resolveWorkspaceGroupConfig(forCwd: anchorCwd)?.newWorkspacePlacement
        return WorkspaceGroupNewWorkspaceTarget(
            groupId: groupId,
            referenceWorkspaceId: selectedWorkspaceId,
            placement: configured
                ?? UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().workspaceGroups.newWorkspacePlacement)
        )
    }

    private func closeInitialWorkspaceIfNeeded(
        initialWorkspaceId: UUID?,
        in context: MainWindowContext?
    ) {
        guard let initialWorkspaceId,
              let context,
              context.tabManager.tabs.count > 1,
              let initialWorkspace = context.tabManager.tabs.first(where: { $0.id == initialWorkspaceId }),
              context.tabManager.selectedWorkspace?.id != initialWorkspaceId else {
            return
        }
        context.tabManager.closeWorkspace(initialWorkspace, recordHistory: false)
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
            openWorkspaceForExternalDirectory(
                workingDirectory: url.path,
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

        VSCodeServeWebController.shared.ensureServeWebURL(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            guard let serveWebURL,
                  let openFolderURL = VSCodeServeWebURLBuilder.openFolderURL(
                      baseWebUIURL: serveWebURL,
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

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openFromServicePasteboard(pasteboard, target: .workspace, error: error)
    }

    private enum ServiceOpenTarget {
        case window
        case workspace
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

        let directories = externalOpenDirectories(from: pathURLs)
        guard !directories.isEmpty else {
            error.pointee = Self.serviceErrorNoPath
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        for directory in directories {
            switch target {
            case .window:
                _ = createMainWindow(initialWorkingDirectory: directory)
            case .workspace:
                openWorkspaceFromService(workingDirectory: directory)
            }
        }
    }

    private func servicePathURLs(from pasteboard: NSPasteboard) -> [URL] {
        let pathURLs = PasteboardFileURLReader.fileURLs(from: pasteboard)
        if !pathURLs.isEmpty {
            return pathURLs
        }

        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            return raw
                .split(whereSeparator: \.isNewline)
                .map { line in
                    let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let fileURL = URL(string: text), fileURL.isFileURL {
                        return fileURL
                    }
                    return URL(fileURLWithPath: text)
                }
        }

        return []
    }

    private func openWorkspaceFromService(workingDirectory: String) {
        openWorkspaceForExternalDirectory(
            workingDirectory: workingDirectory,
            debugSource: "service.openTab"
        )
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

    private func externalOpenDirectories(from urls: [URL]) -> [String] {
        // LaunchServices can surface the running app bundle on relaunch; ignore self paths so
        // they do not get treated as explicit folder opens and suppress session restore.
        FinderServicePathResolver.orderedUniqueDirectories(
            from: urls.filter { $0.isFileURL },
            excludingDescendantsOf: [Bundle.main.bundleURL]
        ).filter {
            !SessionPersistencePolicy.isCmuxCrashStoragePath($0)
        }
    }

    private func externalOpenFileURLs(from urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var fileURLs: [URL] = []
        for url in urls where url.isFileURL && !externalOpenURLIsDirectory(url) {
            let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !externalOpenURLIsDescendantOfCurrentBundle(standardized) else { continue }
            guard !SessionPersistencePolicy.isCmuxCrashStorageURL(standardized) else { continue }
            let path = standardized.path(percentEncoded: false)
            guard seen.insert(path).inserted else { continue }
            fileURLs.append(url.standardizedFileURL)
        }
        return fileURLs
    }

    private func externalOpenURLIsDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.hasDirectoryPath {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func externalOpenURLIsDescendantOfCurrentBundle(_ url: URL) -> Bool {
        let pathComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let bundleComponents = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard pathComponents.count >= bundleComponents.count else { return false }
        return Array(pathComponents.prefix(bundleComponents.count)) == bundleComponents
    }

    private func openWorkspaceForExternalDirectory(
        workingDirectory: String,
        debugSource: String
    ) {
        if addWorkspaceInPreferredMainWindow(
            workingDirectory: workingDirectory,
            shouldBringToFront: true,
            debugSource: debugSource
        ) != nil {
            return
        }
        _ = createMainWindow(initialWorkingDirectory: workingDirectory)
    }

    private func openTerminalDefaultFileRequest(
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
        let context: MainWindowContext? = {
            if let existing = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) {
                return existing
            }
            let windowId = createMainWindow(initialTerminalInput: "", shouldActivate: shouldBringToFront)
            return mainWindowContexts.values.first { $0.windowId == windowId }
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
        let context: MainWindowContext? = {
            if let existing = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) {
                return existing
            }
            let windowId = createMainWindow(initialWorkingDirectory: parentDirectory)
            return mainWindowContexts.values.first { $0.windowId == windowId }
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
        title: String? = nil,
        workingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false,
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
            workspace = context.tabManager.addWorkspace(
                title: title,
                initialSurface: .browser,
                initialBrowserURL: initialBrowserURL,
                initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
                initialBrowserTransparentBackground: initialBrowserTransparentBackground,
                select: true
            )
        } else if workingDirectory != nil || initialTerminalInput != nil {
            workspace = context.tabManager.addWorkspace(
                title: title,
                workingDirectory: workingDirectory,
                initialTerminalInput: initialTerminalInput,
                select: true,
                autoWelcomeIfNeeded: initialTerminalInput == nil
            )
        } else if title != nil {
            workspace = context.tabManager.addWorkspace(title: title, select: true)
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

    func preferredMainWindowContextForWorkspaceCreation(
        event: NSEvent? = nil,
        debugSource: String = "unspecified"
    ) -> MainWindowContext? {
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
        let fallback = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil })
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
    ) -> MainWindowContext? {
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
           let context = mainWindowContexts.values.first(where: { candidate in
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

    func preferredMainWindowContextForShortcutRouting(event: NSEvent) -> MainWindowContext? {
        if let context = mainWindowContext(forShortcutEvent: event, debugSource: "shortcut.routing") {
            return context
        }

        if shortcutEventHasAddressableWindow(event) {
            if let eventWindow = resolvedShortcutEventWindow(event),
               cmuxWindowShouldOwnCloseShortcut(eventWindow) {
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
           let context = mainWindowContexts.values.first(where: { $0.tabManager === activeManager }) {
            return context
        }

        return mainWindowContexts.values.first
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
            && sidebarState === context.sidebarState
            && sidebarSelectionState === context.sidebarSelectionState
        if alreadyActive { return true }

        if let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
        } else {
            tabManager = context.tabManager
            sidebarState = context.sidebarState
            sidebarSelectionState = context.sidebarSelectionState
            fileExplorerState = context.fileExplorerState
            TerminalController.shared.setActiveTabManager(context.tabManager)
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
        let sourceScreen = sourceWindow.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(sourceFrame) })
        guard let visibleFrame = sourceScreen?.visibleFrame else {
            window.center()
            return
        }

        let cascadeOffset: CGFloat = 24
        let minimumWindowSize = NSSize(width: 460, height: 360)
        var frame = window.frame
        frame.origin = NSPoint(
            x: sourceFrame.minX + cascadeOffset,
            y: sourceFrame.maxY - cascadeOffset - frame.height
        )
        window.setFrame(
            Self.clampFrame(
                frame,
                within: visibleFrame,
                minWidth: minimumWindowSize.width,
                minHeight: minimumWindowSize.height
            ),
            display: false
        )
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
            autoWelcomeIfNeeded: initialTerminalInput == nil
        )
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
                ClosedItemHistoryStore.shared.remapWorkspaceWindowIds(from: originalWindowId, to: windowId)
                ClosedItemHistoryStore.shared.flushPendingSaves()
            }
            restoredSessionSnapshotHandler?(restoredPanelIdsByWorkspaceIndex, tabManager)
        }

        let sidebarWidth = sessionWindowSnapshot?.sidebar.width
            .map { SessionPersistencePolicy.sanitizedSidebarWidth($0) }
            ?? SessionPersistencePolicy.defaultSidebarWidth
#if DEBUG
        let shouldStartWithHiddenSidebarForTerminalViewportUITest =
            ProcessInfo.processInfo.environment["CMUX_UI_TEST_TERMINAL_VIEWPORT_HIDE_SIDEBAR"] == "1"
#else
        let shouldStartWithHiddenSidebarForTerminalViewportUITest = false
#endif
        let sidebarState = SidebarState(
            isVisible: shouldStartWithHiddenSidebarForTerminalViewportUITest
                ? false
                : (sessionWindowSnapshot?.sidebar.isVisible ?? true),
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
                ? MinimalModeTitlebarDebugSettings.trafficLightTabBarLeadingInset()
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
            .environmentObject(tabManager)
            .environmentObject(notificationStore)
            .environmentObject(notificationStore.sidebarUnread)
            .environmentObject(sidebarState)
            .environmentObject(sidebarSelectionState)
            .environmentObject(fileExplorerState)
            .environmentObject(cmuxConfigStore)
            // AppKit hosts this ContentView in its own NSHostingView, which does
            // not inherit the App scene's SwiftUI environment. Inject the
            // settings runtime so `@LiveSetting` can resolve the stores it
            // observes throughout the main window (e.g. the sidebar). The key is
            // optional, so a nil runtime just leaves reads at their seeded
            // catalog default.
            .environment(\.settingsRuntime, settingsRuntime)
            .cmuxFontMagnificationEnvironment()

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
            if mainWindowContexts.count >= 1 {
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
        publishCmuxWindowLifecycle(name: "window.created", windowId: windowId, origin: "create")
        installFileDropOverlay(on: window, tabManager: tabManager)
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
                    "applied={\(nsRectLogDescription(window.frame))}"
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
        updateController.attemptUpdate() // re-resolve to the latest version at install time (#6366)
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
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    @objc func restartSocketListener(_ sender: Any?) {
        guard tabManager != nil else {
            NSSound.beep()
            return
        }

        guard socketListenerConfigurationIfEnabled() != nil else {
            TerminalController.shared.stop()
            NSSound.beep()
            return
        }
        restartSocketListenerIfEnabled(source: "menu.command")
    }

    /// All open workspaces across every window, for the Sleepy Mode pet census
    /// (counts the coding agents the user currently has running).
    func openWorkspacesForPetCensus() -> [Workspace] {
        mainWindowContexts.values.flatMap { $0.tabManager.tabs }
    }

    private func setupMenuBarExtra() {
        guard menuBarExtraController == nil else { return }
        removeTransientGlobalSearchMenuBarExtraController()
        menuBarExtraController = makeMenuBarExtraController()
        SleepyModeController.shared.onStateChange = { [weak self] in
            self?.menuBarExtraController?.refreshForDebugControls()
        }
    }

    private func makeMenuBarExtraController() -> MenuBarExtraController {
        let store = TerminalNotificationStore.shared
        return MenuBarExtraController(
            notificationStore: store,
            onShowGlobalSearch: { button, onDismiss in
                GlobalSearchCoordinator.shared.togglePalette(anchor: button, onDismiss: onDismiss)
            },
            onShowMainWindow: { [weak self] in
                self?.showMainWindowFromMenuBar()
            },
            onShowNotifications: { [weak self] in
                self?.showNotificationsPopoverFromMenuBar()
            },
            onOpenNotification: { [weak self] notification in
                _ = self?.openTerminalNotification(notification)
            },
            onJumpToLatestUnread: { [weak self] in
                self?.jumpToLatestUnread()
            },
            onOpenTaskManager: {
                TaskManagerWindowController.shared.show()
            },
            onToggleSleepyMode: {
                SleepyModeController.shared.toggle()
            },
            onCheckForUpdates: { [weak self] in
                self?.checkForUpdates(nil)
            },
            onOpenPreferences: { [weak self] in
                self?.openPreferencesWindow(debugSource: "menuBarExtra")
            },
            onQuitApp: {
                NSApp.terminate(nil)
            }
        )
    }

    func toggleGlobalSearchPaletteFromGlobalHotkey() {
        if menuBarExtraController == nil,
           MenuBarExtraSettings.shouldInstallMenuBarExtra() {
            setupMenuBarExtra()
        }

        if let menuBarExtraController,
           menuBarExtraController.toggleGlobalSearchPalette() {
            return
        }

        if toggleGlobalSearchPaletteFromTransientMenuBarExtra() {
            return
        }

        NSSound.beep()
    }

    private func toggleGlobalSearchPaletteFromTransientMenuBarExtra() -> Bool {
        if let controller = transientGlobalSearchMenuBarExtraController {
            if controller.toggleGlobalSearchPalette(
                onDismiss: transientGlobalSearchDismissalHandler(for: controller)
            ) {
                return true
            }
            controller.removeFromMenuBar()
            transientGlobalSearchMenuBarExtraController = nil
        }

        let controller = makeMenuBarExtraController()
        transientGlobalSearchMenuBarExtraController = controller

        let onDismiss = transientGlobalSearchDismissalHandler(for: controller)

        guard controller.toggleGlobalSearchPalette(onDismiss: onDismiss) else {
            controller.removeFromMenuBar()
            transientGlobalSearchMenuBarExtraController = nil
            return false
        }

        return true
    }

    private func removeTransientGlobalSearchMenuBarExtraController() {
        transientGlobalSearchMenuBarExtraController?.removeFromMenuBar()
        transientGlobalSearchMenuBarExtraController = nil
    }

    private func transientGlobalSearchDismissalHandler(
        for controller: MenuBarExtraController
    ) -> () -> Void {
        return { [weak self, weak controller] in
            guard let self,
                  let controller,
                  self.transientGlobalSearchMenuBarExtraController === controller else {
                return
            }
            controller.removeFromMenuBar()
            self.transientGlobalSearchMenuBarExtraController = nil
        }
    }

    private func installMenuBarVisibilityObserver() {
        guard menuBarVisibilityObserver == nil else { return }
        menuBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncApplicationPresentationPreferences()
            }
        }
    }

    private func syncApplicationPresentationPreferences(defaults: UserDefaults = .standard) {
        MenuBarOnlySettings.normalizeLegacyStoredPreference(defaults: defaults)
        syncActivationPolicy(defaults: defaults)
        syncMenuBarExtraVisibility(defaults: defaults)
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

    private func syncActivationPolicy(defaults: UserDefaults = .standard) {
        MenuBarOnlySettings.applyActivationPolicy(defaults: defaults)
    }

    private func syncMenuBarExtraVisibility(defaults: UserDefaults = .standard) {
        let shouldInstall = MenuBarExtraSettings.shouldInstallMenuBarExtra(defaults: defaults)
        let previousShouldInstall = lastMenuBarExtraShouldInstall
        lastMenuBarExtraShouldInstall = shouldInstall

        if shouldInstall {
            setupMenuBarExtra()
            return
        }

        let hadPersistentController = menuBarExtraController != nil
        menuBarExtraController?.removeFromMenuBar()
        menuBarExtraController = nil
        if previousShouldInstall == true || hadPersistentController {
            removeTransientGlobalSearchMenuBarExtraController()
        }
    }

    @MainActor
    static func presentPreferencesWindow(
        navigationTarget: SettingsNavigationTarget? = nil,
        showFallbackSettingsWindow: @MainActor (SettingsNavigationTarget?) -> Void = { target in
            SettingsWindowPresenter.show(navigationTarget: target)
        },
        activateApplication: @MainActor () -> Void = {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
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
        menuBarExtraController?.refreshForDebugControls()
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

    private func preferredMainWindowForVisibilityActivation() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow,
           isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        if let visibleContext = sortedMainWindowContextsForSessionSnapshot().first(where: { context in
            guard let window = resolvedWindow(for: context) else { return false }
            return window.isVisible && !window.isMiniaturized
        }) {
            return resolvedWindow(for: visibleContext)
        }
        return sortedMainWindowContextsForSessionSnapshot()
            .compactMap { resolvedWindow(for: $0) }
            .first
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

    func mainWindowsForVisibilityController() -> [NSWindow] {
        var windows: [NSWindow] = []
        for context in sortedMainWindowContextsForSessionSnapshot() {
            guard let window = resolvedWindow(for: context) else { continue }
            if !windows.contains(where: { $0 === window }) {
                windows.append(window)
            }
        }
        for window in NSApp.windows where isMainTerminalWindow(window) {
            if !windows.contains(where: { $0 === window }) {
                windows.append(window)
            }
        }
        return windows
    }

    func showNotificationsPopoverFromMenuBar() {
        let context: MainWindowContext? = {
            if let keyWindow = NSApp.keyWindow,
               let keyContext = contextForMainTerminalWindow(keyWindow) {
                return keyContext
            }
            if let first = mainWindowContexts.values.first {
                return first
            }
            let windowId = createMainWindow()
            return mainWindowContexts.values.first(where: { $0.windowId == windowId })
        }()

        if let context,
           let window = context.window ?? windowForMainWindowId(context.windowId) {
            setActiveMainWindow(window)
            bringToFront(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.titlebarAccessoryController.showNotificationsPopover(animated: false)
        }
    }

    #if DEBUG
    @objc func showUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateController.model.setOverrideState(.installing(.init(isAutoUpdate: true, retryTerminatingApplication: {}, dismiss: {})))
    }

    @objc func showUpdatePillLongNightly(_ sender: Any?) {
        updateViewModel.debugOverrideText = "Update Available: 0.32.0-nightly+20260216.abc1234"
        updateController.model.setOverrideState(.notFound(.init(acknowledgement: {})))
    }

    @objc func showUpdatePillLoading(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateController.model.setOverrideState(.checking(.init(cancel: {})))
    }

    @objc func hideUpdatePill(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateController.model.setOverrideState(.idle)
    }

    @objc func clearUpdatePillOverride(_ sender: Any?) {
        updateViewModel.debugOverrideText = nil
        updateController.model.setOverrideState(nil)
    }
#endif

    @objc func copyUpdateLogs(_ sender: Any?) {
        let logText = updateLog.snapshot()
        let payload: String
        if logText.isEmpty {
            payload = "No update logs captured.\nLog file: \(updateLog.logPath())"
        } else {
            payload = logText + "\nLog file: \(updateLog.logPath())"
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
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

    @objc private func handleFeedRequestFocus(_ notification: Notification) {
        guard let workspaceId = notification.userInfo?["workspaceId"] as? String,
              let surfaceId = notification.userInfo?["surfaceId"] as? String
        else { return }

        // Invoke the existing V2 commands so the Feed-layer focus request
        // goes through the same code path as a socket-initiated focus.
        // Serialize through JSON so we reuse the v2 command parser.
        let controller = TerminalController.shared
        let invoke: (String, [String: Any]) -> Void = { method, params in
            let payload: [String: Any] = [
                "id": UUID().uuidString,
                "method": method,
                "params": params
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            _ = controller.handleSocketLine(line)
        }
        invoke("workspace.select", ["workspace_id": workspaceId])
        invoke("surface.focus", ["surface_id": surfaceId])
        // Flash the terminal's own focus ring (same visual as
        // cmd+shift+H / Flash Focused Panel) so the user's eye is
        // pulled to the terminal content the Feed jumped to.
        invoke("surface.trigger_flash", ["surface_id": surfaceId])
    }

    @objc private func handleFeedRequestSendText(_ notification: Notification) {
        guard let surfaceId = notification.userInfo?["surfaceId"] as? String,
              let text = notification.userInfo?["text"] as? String,
              !text.isEmpty
        else { return }

        let controller = TerminalController.shared
        let invoke: (String, [String: Any]) -> Void = { method, params in
            let payload: [String: Any] = [
                "id": UUID().uuidString,
                "method": method,
                "params": params,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let line = String(data: data, encoding: .utf8)
            else { return }
            _ = controller.handleSocketLine(line)
        }
        // Terminal-mode Return is CR. sendNamedKey "Return" also works
        // but one send_text is atomic, so append CR directly.
        invoke("surface.send_text", [
            "surface_id": surfaceId,
            "text": text + "\r",
        ])
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

    private func sendTextWhenReady(
        _ text: String,
        to tab: Tab,
        preferredPanelId: UUID? = nil,
        beforeSend: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        let isReactGrabPasteback = preferredPanelId != nil
#if DEBUG
        let initialTargetPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        )
        if isReactGrabPasteback {
            cmuxDebugLog(
                "reactGrab.pasteback h2.send.start " +
                "workspace=\(Self.debugShortId(tab.id)) " +
                "preferred=\(Self.debugShortId(preferredPanelId)) " +
                "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                "focusedTerminal=\(Self.debugShortId(tab.focusedTerminalPanel?.id)) " +
                "resolved=\(Self.debugShortId(initialTargetPanel?.id)) " +
                "surfaceReady=\(initialTargetPanel?.surface.surface != nil ? 1 : 0) len=\(text.count)"
            )
        }
#endif
        if let terminalPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        ),
           terminalPanel.isAgentHibernated {
            beforeSend?()
            if !terminalPanel.sendText(text) {
                onFailure?()
            }
            return
        }

        if let terminalPanel = Self.resolveTerminalPanelForTextSend(
            in: tab,
            preferredPanelId: preferredPanelId
        ),
           terminalPanel.surface.surface != nil {
#if DEBUG
            if isReactGrabPasteback {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.send.immediate " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) len=\(text.count)"
                )
            }
#endif
            beforeSend?()
            let didSend = terminalPanel.sendText(text)
#if DEBUG
            if isReactGrabPasteback, didSend {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.send.sent " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) mode=immediate len=\(text.count)"
                )
            }
#endif
            if !didSend {
                onFailure?()
            }
            return
        }

        Self.resolveTerminalPanelForTextSend(in: tab, preferredPanelId: preferredPanelId)?.surface.requestInputDemandSurfaceStartIfNeeded()
        var resolved = false
        var readyObserver: NSObjectProtocol?
        var focusObserver: NSObjectProtocol?
        var firstResponderObserver: NSObjectProtocol?
        var panelsCancellable: AnyCancellable?

        func cleanupObservers() {
            if let readyObserver {
                NotificationCenter.default.removeObserver(readyObserver)
            }
            if let focusObserver {
                NotificationCenter.default.removeObserver(focusObserver)
            }
            if let firstResponderObserver {
                NotificationCenter.default.removeObserver(firstResponderObserver)
            }
            panelsCancellable?.cancel()
        }

        func finishIfReady() {
            let terminalPanel = Self.resolveTerminalPanelForTextSend(
                in: tab,
                preferredPanelId: preferredPanelId
            )
#if DEBUG
            if isReactGrabPasteback {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.finishIfReady " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "preferred=\(Self.debugShortId(preferredPanelId)) " +
                    "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                    "resolved=\(Self.debugShortId(terminalPanel?.id)) " +
                    "surfaceReady=\(terminalPanel?.surface.surface != nil ? 1 : 0) alreadyResolved=\(resolved ? 1 : 0)"
                )
            }
#endif
            guard !resolved,
                  let terminalPanel,
                  terminalPanel.surface.surface != nil else { return }
            resolved = true
            cleanupObservers()
            beforeSend?()
            let didSend = terminalPanel.sendText(text)
#if DEBUG
            if isReactGrabPasteback, didSend {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.send.sent " +
                    "workspace=\(Self.debugShortId(tab.id)) " +
                    "target=\(Self.debugShortId(terminalPanel.id)) mode=delayed len=\(text.count)"
                )
            }
#endif
            if !didSend {
                onFailure?()
            }
        }

        panelsCancellable = tab.panelsPublisher
            .map { _ in () }
            .sink { _ in
#if DEBUG
                if isReactGrabPasteback {
                    cmuxDebugLog(
                        "reactGrab.pasteback h2.panelsChanged " +
                        "workspace=\(Self.debugShortId(tab.id)) " +
                        "focused=\(Self.debugShortId(tab.focusedPanelId))"
                    )
                }
#endif
                finishIfReady()
            }
        if isReactGrabPasteback {
            focusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tab.id,
                      let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                    return
                }
#if DEBUG
                cmuxDebugLog(
                    "reactGrab.pasteback h1.focusEvent " +
                    "workspace=\(Self.debugShortId(candidateTabId)) " +
                    "surface=\(Self.debugShortId(candidateSurfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(candidateSurfaceId == preferredPanelId ? 1 : 0)"
                )
#endif
            }
            firstResponderObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidBecomeFirstResponderSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tab.id,
                      let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else {
                    return
                }
#if DEBUG
                cmuxDebugLog(
                    "reactGrab.pasteback h1.firstResponderEvent " +
                    "workspace=\(Self.debugShortId(candidateTabId)) " +
                    "surface=\(Self.debugShortId(candidateSurfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(candidateSurfaceId == preferredPanelId ? 1 : 0)"
                )
#endif
            }
        }
        readyObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  workspaceId == tab.id else { return }
            let surfaceId = note.userInfo?["surfaceId"] as? UUID
#if DEBUG
            if isReactGrabPasteback {
                cmuxDebugLog(
                    "reactGrab.pasteback h2.surfaceReadyEvent " +
                    "workspace=\(Self.debugShortId(workspaceId)) " +
                    "surface=\(Self.debugShortId(surfaceId)) " +
                    "target=\(Self.debugShortId(preferredPanelId)) " +
                    "match=\(surfaceId == preferredPanelId ? 1 : 0)"
                )
            }
#endif
            if let preferredPanelId,
               let surfaceId,
               surfaceId != preferredPanelId {
                return
            }
            finishIfReady()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if !resolved {
                resolved = true
#if DEBUG
                if isReactGrabPasteback {
                    cmuxDebugLog(
                        "reactGrab.pasteback h2.send.timeout " +
                        "workspace=\(Self.debugShortId(tab.id)) " +
                        "preferred=\(Self.debugShortId(preferredPanelId)) " +
                        "focused=\(Self.debugShortId(tab.focusedPanelId)) " +
                        "focusedTerminal=\(Self.debugShortId(tab.focusedTerminalPanel?.id))"
                    )
                }
#endif
                cleanupObservers()
                NSLog("Command send: surface not ready after 3.0s")
                onFailure?()
            }
        }
    }

#if DEBUG
    private let debugColorWorkspaceTitlePrefix = "Debug Color - "
    private let debugPerfWorkspaceTitlePrefix = "Debug Perf - "
    private var debugStressWorkspaceCreationInProgress = false
    private var debugStressLagProbeEnabled = false
    private let debugStressWorkspaceCount = 20
    private let debugStressPaneCount = 4
    private let debugStressTabsPerPane = 4
    private let debugStressYieldInterval = 4
    private let debugStressSurfaceLoadTimeoutSeconds: TimeInterval = 10.0

    @objc func openDebugScrollbackTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let config = GhosttyConfig.load()
        let minimumTargetBytes = 2_000_000
        let maximumTargetBytes = 200_000_000
        let minimumLineCount = 2000
        let effectiveLimit = max(config.scrollbackLimit, 0)
        let doubledLimit = min(effectiveLimit, maximumTargetBytes / 2) * 2
        let targetBytes = min(max(doubledLimit, minimumTargetBytes), maximumTargetBytes)
        // `%06d` guarantees at least a 6-digit field width. Any lines beyond
        // 999,999 only get wider, so this conservative floor always emits at
        // least `targetBytes` without oscillating at digit-count boundaries.
        let baseBytesPerLine = "scrollback 000000\n".utf8.count
        let lineCount = max((targetBytes + baseBytesPerLine - 1) / baseBytesPerLine, minimumLineCount)

        let command = #"awk 'BEGIN { for (i = 1; i <= \#(lineCount); ++i) printf "scrollback %06d\n", i }'"# + "\n"
        sendTextWhenReady(command, to: tab)
    }

    @objc func openDebugLoremTab(_ sender: Any?) {
        guard let tabManager else { return }
        let tab = tabManager.addTab()
        let lineCount = 2000
        let base = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        for index in 1...lineCount {
            lines.append(String(format: "%04d %@", index, base))
        }
        let payload = lines.joined(separator: "\n") + "\n"
        sendTextWhenReady(payload, to: tab)
    }

    @objc func openDebugAgentSessionReact(_ sender: Any?) {
        openDebugAgentSession(rendererKind: .react)
    }

    @objc func openDebugAgentSessionSolid(_ sender: Any?) {
        openDebugAgentSession(rendererKind: .solid)
    }

    private func openDebugAgentSession(rendererKind: AgentSessionRendererKind) {
        guard let manager = activeTabManagerForCommands(),
              let workspace = manager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        _ = workspace.newAgentSessionSurface(
            inPane: paneId,
            providerID: .codex,
            rendererKind: rendererKind,
            workingDirectory: workspace.currentDirectory,
            focus: true
        )
    }

    @objc func openDebugColorComparisonWorkspaces(_ sender: Any?) {
        guard let tabManager else { return }

        let palette = WorkspaceTabColorSettings.palette()
        guard !palette.isEmpty else { return }

        var existingByTitle: [String: Workspace] = [:]
        for tab in tabManager.tabs {
            guard let title = tab.customTitle,
                  title.hasPrefix(debugColorWorkspaceTitlePrefix) else { continue }
            existingByTitle[title] = tab
        }

        for entry in palette {
            let title = "\(debugColorWorkspaceTitlePrefix)\(entry.name)"
            let targetTab: Workspace
            if let existing = existingByTitle[title] {
                targetTab = existing
            } else {
                targetTab = tabManager.addTab()
            }
            tabManager.setCustomTitle(tabId: targetTab.id, title: title)
            tabManager.setTabColor(tabId: targetTab.id, color: entry.hex)
        }
    }

    @objc func openDebugStressWorkspacesWithLoadedSurfaces(_ sender: Any?) {
        guard !debugStressWorkspaceCreationInProgress else { return }
        guard let tabManager else { return }

        debugStressLagProbeEnabled = true
        debugStressWorkspaceCreationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.debugStressWorkspaceCreationInProgress = false }

            let totalStart = ProcessInfo.processInfo.systemUptime
            let originalSelectedWorkspaceId = tabManager.selectedTabId
            var created: [Workspace] = []
            created.reserveCapacity(self.debugStressWorkspaceCount)
            var layoutFailures = 0
            var cumulativeWorkspaceMs: Double = 0
            var slowWorkspaceCount = 0
            var worstWorkspaceMs: Double = 0

            cmuxDebugLog(
                "stress.setup.start workspaces=\(self.debugStressWorkspaceCount) panes=\(self.debugStressPaneCount) " +
                "tabsPerPane=\(self.debugStressTabsPerPane) lagProbe=1"
            )

            for index in 0..<self.debugStressWorkspaceCount {
                let workspaceStart = ProcessInfo.processInfo.systemUptime
                let workspace = tabManager.addWorkspace(select: false, placementOverride: .end)
                created.append(workspace)
                tabManager.setCustomTitle(
                    tabId: workspace.id,
                    title: "\(self.debugPerfWorkspaceTitlePrefix)\(index + 1)"
                )

                if !(await self.configureDebugStressWorkspaceLayout(
                    workspace,
                    paneCount: self.debugStressPaneCount,
                    tabsPerPane: self.debugStressTabsPerPane
                )) {
                    layoutFailures += 1
                }

                let workspaceMs = (ProcessInfo.processInfo.systemUptime - workspaceStart) * 1000.0
                cumulativeWorkspaceMs += workspaceMs
                worstWorkspaceMs = max(worstWorkspaceMs, workspaceMs)
                if workspaceMs >= 35 {
                    slowWorkspaceCount += 1
                }

                if workspaceMs >= 35 || ((index + 1) % 5 == 0) {
                    let pending = self.pendingDebugTerminalSurfaceCount(in: created)
                    cmuxDebugLog(
                        "stress.setup.workspace idx=\(index + 1)/\(self.debugStressWorkspaceCount) " +
                        "ms=\(String(format: "%.2f", workspaceMs)) failures=\(layoutFailures) pending=\(pending)"
                    )
                }

                if ((index + 1) % self.debugStressYieldInterval) == 0 {
                    await Task.yield()
                }
            }

            let creationElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let loadStats = await self.loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
                created,
                tabManager: tabManager
            )
            let totalElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let avgWorkspaceMs = created.isEmpty ? 0 : (cumulativeWorkspaceMs / Double(created.count))
            let expectedSurfaceCount = self.debugStressWorkspaceCount
                * self.debugStressPaneCount
                * self.debugStressTabsPerPane
            if let originalSelectedWorkspaceId,
               tabManager.tabs.contains(where: { $0.id == originalSelectedWorkspaceId }) {
                tabManager.selectedTabId = originalSelectedWorkspaceId
            }

            cmuxDebugLog(
                "stress.setup.done createMs=\(String(format: "%.2f", creationElapsedMs)) " +
                "loadMs=\(String(format: "%.2f", loadStats.elapsedMs)) loadedPanels=\(loadStats.loadedPanels) " +
                "loadFailures=\(loadStats.failedPanels) totalMs=\(String(format: "%.2f", totalElapsedMs)) " +
                "workspaceAvgMs=\(String(format: "%.2f", avgWorkspaceMs)) workspaceWorstMs=\(String(format: "%.2f", worstWorkspaceMs)) " +
                "workspaceSlowCount=\(slowWorkspaceCount) waitAttempts=\(loadStats.attempts) " +
                "pendingSurfaces=\(loadStats.pendingSurfaces) expectedSurfaces=\(expectedSurfaceCount)"
            )

            NSLog(
                "Debug stress workspaces: created=%d panesPerWorkspace=%d tabsPerPane=%d expectedSurfaces=%d layoutFailures=%d pendingSurfaces=%d createMs=%.2f loadMs=%.2f loadedPanels=%d failedPanels=%d totalMs=%.2f workspaceAvgMs=%.2f workspaceWorstMs=%.2f waitAttempts=%d",
                self.debugStressWorkspaceCount,
                self.debugStressPaneCount,
                self.debugStressTabsPerPane,
                expectedSurfaceCount,
                layoutFailures,
                loadStats.pendingSurfaces,
                creationElapsedMs,
                loadStats.elapsedMs,
                loadStats.loadedPanels,
                loadStats.failedPanels,
                totalElapsedMs,
                avgWorkspaceMs,
                worstWorkspaceMs,
                loadStats.attempts
            )
        }
    }

    private func configureDebugStressWorkspaceLayout(
        _ workspace: Workspace,
        paneCount: Int,
        tabsPerPane: Int
    ) async -> Bool {
        guard let topLeftPanelId = workspace.focusedTerminalPanel?.id ?? workspace.focusedPanelId else {
            return false
        }
        guard let topRight = workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topRight.id,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()

        let paneIds = workspace.bonsplitController.allPaneIds
        guard paneIds.count == paneCount else { return false }

        let additionalTabsPerPane = max(0, tabsPerPane - 1)
        if additionalTabsPerPane > 0 {
            for (paneIndex, paneId) in paneIds.enumerated() {
                for tabOffset in 0..<additionalTabsPerPane {
                    guard workspace.newTerminalSurface(inPane: paneId, focus: false) != nil else {
                        return false
                    }
                    if ((tabOffset + 1) % debugStressYieldInterval) == 0 {
                        await Task.yield()
                    }
                }
                if ((paneIndex + 1) % debugStressYieldInterval) == 0 {
                    await Task.yield()
                }
            }
        }

        return true
    }

    private struct DebugStressSurfaceLoadStats {
        let pendingSurfaces: Int
        let loadedPanels: Int
        let failedPanels: Int
        let attempts: Int
        let elapsedMs: Double
    }

    private struct DebugStressTerminalLoadTarget {
        let workspace: Workspace
        let paneId: PaneID
        let tabId: TabID
        let panelId: UUID
    }

    private func waitForDebugStressCondition(
        timeout: TimeInterval,
        installObservers: (@escaping () -> Void) -> [NSObjectProtocol],
        evaluate: @escaping () -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            var observers: [NSObjectProtocol] = []
            var timeoutWorkItem: DispatchWorkItem?
            var finished = false

            func cleanup() {
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers.removeAll()
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
            }

            func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                cleanup()
                continuation.resume(returning: result)
            }

            let trigger = {
                if evaluate() {
                    finish(true)
                }
            }

            observers = installObservers {
                DispatchQueue.main.async {
                    trigger()
                }
            }
            let workItem = DispatchWorkItem {
                finish(evaluate())
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
            trigger()
        }
    }

    private func loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
        _ workspaces: [Workspace],
        tabManager: TabManager
    ) async -> DebugStressSurfaceLoadStats {
        guard !workspaces.isEmpty else {
            return DebugStressSurfaceLoadStats(
                pendingSurfaces: 0,
                loadedPanels: 0,
                failedPanels: 0,
                attempts: 0,
                elapsedMs: 0
            )
        }

        let retainedWorkspaceIds = Set(workspaces.map(\.id))
        let loadStart = ProcessInfo.processInfo.systemUptime
        var attempts = 0
        var queuedTargets: [DebugStressTerminalLoadTarget] = []
        queuedTargets.reserveCapacity(
            workspaces.count * debugStressPaneCount * debugStressTabsPerPane
        )

        tabManager.retainDebugWorkspaceLoads(for: retainedWorkspaceIds)
        defer { tabManager.releaseDebugWorkspaceLoads(for: retainedWorkspaceIds) }

        await Task.yield()
        forceDebugStressVisibleLayout()
        let mountedWorkspaceCount = await waitForDebugStressMountedWorkspaces(workspaces)

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for paneId in workspace.bonsplitController.allPaneIds {
                for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                    guard let panelId = workspace.panelIdFromSurfaceId(tab.id),
                          workspace.panel(for: tab.id) is TerminalPanel else {
                        continue
                    }
                    if workspace.preloadTerminalPanelForDebugStress(tabId: tab.id, inPane: paneId) != nil {
                        queuedTargets.append(
                            DebugStressTerminalLoadTarget(
                                workspace: workspace,
                                paneId: paneId,
                                tabId: tab.id,
                                panelId: panelId
                            )
                        )
                        attempts += 1
                    }
                }
            }

            cmuxDebugLog(
                "stress.setup.queue workspace=\(workspaceIndex + 1)/\(workspaces.count) " +
                "mounted=\(mountedWorkspaceCount)/\(workspaces.count) queued=\(queuedTargets.count)"
            )
            await Task.yield()
        }

        let waitResult = await waitForDebugStressTerminalPanelSurfaces(queuedTargets)
        attempts += waitResult.attempts
        let failedPanels = waitResult.pendingTargets.count
        let loadedPanels = max(0, queuedTargets.count - failedPanels)
        for target in waitResult.pendingTargets {
            cmuxDebugLog(
                "stress.setup.surfaceTimeout workspace=\(target.workspace.id.uuidString.prefix(5)) " +
                "panel=\(target.panelId.uuidString.prefix(5)) pane=\(target.paneId.id.uuidString.prefix(5))"
            )
        }

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000.0
        return DebugStressSurfaceLoadStats(
            pendingSurfaces: pendingDebugTerminalSurfaceCount(in: workspaces),
            loadedPanels: loadedPanels,
            failedPanels: failedPanels,
            attempts: attempts,
            elapsedMs: elapsedMs
        )
    }

    private func waitForDebugStressMountedWorkspaces(_ workspaces: [Workspace]) async -> Int {
        guard !workspaces.isEmpty else { return 0 }
        var mountedWorkspaceCount = 0
        let selectedWorkspaceId = tabManager?.selectedTabId

        let updateMountedCount = { [self] in
            self.forceDebugStressVisibleLayout()
            mountedWorkspaceCount = 0
            for workspace in workspaces {
                if workspace.id == selectedWorkspaceId {
                    workspace.scheduleDebugStressTerminalGeometryReconcile()
                } else {
                    workspace.panels.values.compactMap { $0 as? TerminalPanel }.forEach { $0.surface.requestBackgroundSurfaceStartIfNeeded() }
                }
                if workspace.panels.values.contains(where: { panel in
                    guard let terminalPanel = panel as? TerminalPanel else { return false }
                    return terminalPanel.hostedView.superview != nil || terminalPanel.surface.surface != nil
                }) {
                    mountedWorkspaceCount += 1
                }
            }
        }
        let _ = await waitForDebugStressCondition(
            timeout: 0.25,
            installObservers: { trigger in
                [
                    NotificationCenter.default.addObserver(
                        forName: .terminalSurfaceDidBecomeReady,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    },
                    NotificationCenter.default.addObserver(
                        forName: .terminalSurfaceHostedViewDidMoveToWindow,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    },
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didUpdateNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    }
                ]
            },
            evaluate: {
                updateMountedCount()
                return mountedWorkspaceCount == workspaces.count
            }
        )

        cmuxDebugLog("stress.setup.mount mounted=\(mountedWorkspaceCount)/\(workspaces.count)")
        return mountedWorkspaceCount
    }

    private func waitForDebugStressTerminalPanelSurfaces(
        _ targets: [DebugStressTerminalLoadTarget]
    ) async -> (pendingTargets: [DebugStressTerminalLoadTarget], attempts: Int) {
        guard !targets.isEmpty else {
            return (pendingTargets: [], attempts: 0)
        }

        let deadline = Date().addingTimeInterval(debugStressSurfaceLoadTimeoutSeconds)
        let selectedWorkspaceId = tabManager?.selectedTabId
        var pendingTargets = targets
        var attempts = 0
        var eventCount = 0

        func refreshPendingTargets() {
            self.forceDebugStressVisibleLayout()
            var nextPending: [DebugStressTerminalLoadTarget] = []
            nextPending.reserveCapacity(pendingTargets.count)
            var startedThisPass = 0

            for target in pendingTargets {
                guard let terminalPanel = target.workspace.panel(for: target.tabId) as? TerminalPanel else {
                    nextPending.append(target)
                    continue
                }
                if terminalPanel.surface.surface != nil {
                    continue
                }

                let hostedView = terminalPanel.hostedView
                let shouldReconcileVisibleSelection =
                    target.workspace.id == selectedWorkspaceId &&
                    terminalPanel.surface.isViewInWindow &&
                    hostedView.superview != nil

                if shouldReconcileVisibleSelection {
                    target.workspace.scheduleDebugStressTerminalGeometryReconcile()
                    terminalPanel.requestViewReattach()
                }
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                startedThisPass += 1
                nextPending.append(target)
            }

            eventCount += 1
            if nextPending.count != pendingTargets.count || startedThisPass > 0 || eventCount == 1 {
                cmuxDebugLog(
                    "stress.setup.await event=\(eventCount) pending=\(nextPending.count) " +
                    "started=\(startedThisPass)"
                )
            }
            attempts += startedThisPass
            pendingTargets = nextPending
        }
        refreshPendingTargets()
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0, !pendingTargets.isEmpty {
            let _ = await waitForDebugStressCondition(
                timeout: remaining,
                installObservers: { trigger in
                    [
                        NotificationCenter.default.addObserver(
                            forName: .terminalSurfaceDidBecomeReady,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        },
                        NotificationCenter.default.addObserver(
                            forName: .terminalSurfaceHostedViewDidMoveToWindow,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        },
                        NotificationCenter.default.addObserver(
                            forName: NSWindow.didUpdateNotification,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        }
                    ]
                },
                evaluate: {
                    refreshPendingTargets()
                    return pendingTargets.isEmpty
                }
            )
        }

        return (pendingTargets: pendingTargets, attempts: attempts)
    }

    private func forceDebugStressVisibleLayout() {
        if let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            activeWindow.contentView?.layoutSubtreeIfNeeded()
            activeWindow.contentView?.displayIfNeeded()
            return
        }

        for (windowIndex, window) in NSApp.windows.enumerated() {
            window.contentView?.layoutSubtreeIfNeeded()
            if windowIndex == 0 {
                window.contentView?.displayIfNeeded()
            }
        }
    }

    private func pendingDebugTerminalSurfaceCount(in workspaces: [Workspace]) -> Int {
        var pending = 0
        for workspace in workspaces {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                if terminalPanel.surface.surface == nil {
                    pending += 1
                }
            }
        }
        return pending
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
    private func setupJumpUnreadUITestIfNeeded() {
        guard !didSetupJumpUnreadUITest else { return }
        didSetupJumpUnreadUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let notificationStore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // In UI tests, the initial SwiftUI `WindowGroup` window can lag behind launch. Wait for a
                // registered main terminal window context so notifications can be routed back correctly.
                let deadline = Date().addingTimeInterval(8.0)
                @MainActor func waitForContext(_ completion: @escaping (MainWindowContext) -> Void) {
                    if let context = self.mainWindowContexts.values.first,
                       context.window != nil {
                        completion(context)
                        return
                    }
                    guard Date() < deadline else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        Task { @MainActor in
                            waitForContext(completion)
                        }
                    }
                }

                waitForContext { context in
                    let tabManager = context.tabManager
                    let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
                    let tab = tabManager.addTab()
                    guard let initialPanelId = tab.focusedPanelId else { return }

                    _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialPanelId, direction: .right)
                    guard let targetPanelId = tab.focusedPanelId else { return }
                    // Find another panel that's not the currently focused one
                    let otherPanelId = tab.panels.keys.first(where: { $0 != targetPanelId })
                    if let otherPanelId {
                        tab.focusPanel(otherPanelId)
                    }

                    // Avoid flakiness in the VM where focus can lag selection by a tick, which would
                    // cause notification suppression to incorrectly drop this UI-test notification.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    notificationStore.addNotification(
                        tabId: tab.id,
                        surfaceId: targetPanelId,
                        title: "JumpToUnread",
                        subtitle: "",
                        body: ""
                    )
                    AppFocusState.overrideIsFocused = prevOverride

                    self.writeJumpUnreadTestData([
                        "expectedTabId": tab.id.uuidString,
                        "expectedSurfaceId": targetPanelId.uuidString
                    ])

                    tabManager.selectTab(at: initialIndex)
                }
            }
        }
    }

    func recordJumpToUnreadFocus(tabId: UUID, surfaceId: UUID) {
        writeJumpUnreadTestData([
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId.uuidString
        ])
    }

    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
        installJumpUnreadFocusObserverIfNeeded()
    }

    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = jumpUnreadFocusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        jumpUnreadFocusExpectation = nil
        recordJumpToUnreadFocus(tabId: tabId, surfaceId: surfaceId)
        if let jumpUnreadFocusObserver {
            NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
            self.jumpUnreadFocusObserver = nil
        }
    }

    private func installJumpUnreadFocusObserverIfNeeded() {
        guard jumpUnreadFocusObserver == nil else { return }
        jumpUnreadFocusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self.recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
        }
    }

    func writeJumpUnreadTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        var payload = loadJumpUnreadTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadJumpUnreadTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupGotoSplitUITestIfNeeded() {
        guard !didSetupGotoSplitUITest else { return }
        didSetupGotoSplitUITest = true
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1" {
            installGotoSplitUITestFocusObserversIfNeeded()
            startGotoSplitRecordOnlyRecorder()
            return
        }
        guard env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" else { return }
        guard tabManager != nil else { return }

        let useGhosttyConfig = env["CMUX_UI_TEST_GOTO_SPLIT_USE_GHOSTTY_CONFIG"] == "1"

        if useGhosttyConfig {
            // Keep the test hermetic: ensure the app does not accidentally pass using a persisted
            // KeyboardShortcutSettings override instead of the Ghostty config-trigger path.
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusLeftKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusRightKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusUpKey)
            UserDefaults.standard.removeObject(forKey: KeyboardShortcutSettings.focusDownKey)
        } else {
            // For this UI test we want a letter-based shortcut (Cmd+Ctrl+H) to drive pane navigation,
            // since arrow keys can't be recorded by the shortcut recorder.
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
                for: .focusLeft
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
                for: .focusRight
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
                for: .focusUp
            )
            KeyboardShortcutSettings.setShortcut(
                StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
                for: .focusDown
            )
        }

        installGotoSplitUITestFocusObserversIfNeeded()

        // On the VM, launching/initializing multiple windows can occasionally take longer than a
        // few seconds; keep the deadline generous so the test doesn't flake.
        let deadline = Date().addingTimeInterval(20.0)
        func hasMainTerminalWindow() -> Bool {
            NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
            }
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeGotoSplitTestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard hasMainTerminalWindow() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }
            guard let tabManager = self.tabManager else { return }

            let tab = tabManager.addTab()
            guard let initialPanelId = tab.focusedPanelId else {
                self.writeGotoSplitTestData(["setupError": "Missing initial panel id"])
                return
            }

            let requestedBrowserURL = env["CMUX_UI_TEST_GOTO_SPLIT_BROWSER_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = requestedBrowserURL.flatMap { rawURL in
                guard !rawURL.isEmpty else { return nil }
                return URL(string: rawURL)
            } ?? URL(string: "https://example.com")
            guard let url else {
                self.writeGotoSplitTestData(["setupError": "Invalid browser URL"])
                return
            }
            guard let browserPanelId = tabManager.newBrowserSplit(
                tabId: tab.id,
                fromPanelId: initialPanelId,
                orientation: .horizontal,
                url: url
            ) else {
                self.writeGotoSplitTestData(["setupError": "Failed to create browser split"])
                return
            }

            self.focusWebViewForGotoSplitUITest(tab: tab, browserPanelId: browserPanelId)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self != nil else { return }
            runSetupWhenWindowReady()
        }
    }

    private func setupBonsplitTabDragUITestIfNeeded() {
        guard !didSetupBonsplitTabDragUITest else { return }
        didSetupBonsplitTabDragUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
        guard tabManager != nil else { return }
        let startWithHiddenSidebar = env["CMUX_UI_TEST_BONSPLIT_START_WITH_HIDDEN_SIDEBAR"] == "1"
        let showRightSidebar = env["CMUX_UI_TEST_BONSPLIT_SHOW_RIGHT_SIDEBAR"] == "1"

        let deadline = Date().addingTimeInterval(20.0)
        func mainWindowContextForUITest() -> (window: NSWindow, context: MainWindowContext)? {
            for window in NSApp.windows {
                guard let raw = window.identifier?.rawValue else { continue }
                guard raw == "cmux.main" || raw.hasPrefix("cmux.main.") else { continue }
                guard let context = self.contextForMainTerminalWindow(window),
                      context.fileExplorerState != nil else {
                    continue
                }
                return (window, context)
            }
            return nil
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeBonsplitTabDragUITestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard let (mainWindow, context) = mainWindowContextForUITest() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }

            let screenFrame = mainWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            if let screenFrame {
                let targetSize: NSSize
                if let rawSize = env["CMUX_UI_TEST_BONSPLIT_WINDOW_SIZE"] {
                    let parts = rawSize
                        .split(separator: "x", maxSplits: 1)
                        .compactMap { Double(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
                    if parts.count == 2 {
                        targetSize = NSSize(
                            width: min(max(320, parts[0]), screenFrame.width - 80),
                            height: min(max(240, parts[1]), screenFrame.height - 80)
                        )
                    } else {
                        targetSize = NSSize(width: min(960, screenFrame.width - 80), height: min(720, screenFrame.height - 80))
                    }
                } else {
                    targetSize = NSSize(width: min(960, screenFrame.width - 80), height: min(720, screenFrame.height - 80))
                }
                let targetOrigin = NSPoint(
                    x: screenFrame.minX + 40,
                    y: screenFrame.maxY - 40 - targetSize.height
                )
                let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
                if !mainWindow.frame.equalTo(targetFrame) {
                    mainWindow.setFrame(targetFrame, display: true)
                }
            }
            let tabManager = context.tabManager
            guard let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first,
                  let alphaPanelId = workspace.focusedPanelId else {
                self.writeBonsplitTabDragUITestData(["setupError": "Missing initial workspace or panel"])
                return
            }

            let workspaceTitle = "UITest Workspace"
            let alphaTitle = "UITest Alpha"
            let betaTitle = "UITest Beta"
            tabManager.setCustomTitle(tabId: workspace.id, title: workspaceTitle)
            workspace.setPanelCustomTitle(panelId: alphaPanelId, title: alphaTitle)
            tabManager.newSurface()

            guard let betaPanelId = workspace.focusedPanelId, betaPanelId != alphaPanelId else {
                self.writeBonsplitTabDragUITestData(["setupError": "Failed to create second surface"])
                return
            }

            workspace.setPanelCustomTitle(panelId: betaPanelId, title: betaTitle)
            if let rawActionButtonCount = env["CMUX_UI_TEST_BONSPLIT_ACTION_BUTTON_COUNT"],
               let requestedActionButtonCount = Int(rawActionButtonCount),
               requestedActionButtonCount > 0 {
                guard let cmuxConfigStore = context.cmuxConfigStore else {
                    self.writeBonsplitTabDragUITestData(["setupError": "Missing cmux config store"])
                    return
                }
                let actionButtonCount = min(requestedActionButtonCount, 32)
                let buttons = (1...actionButtonCount).map { index in
                    let actionTitle = String(
                        format: String(
                            localized: "uiTest.bonsplit.action.title",
                            defaultValue: "UITest Action %lld"
                        ),
                        Int64(index)
                    )
                    return CmuxSurfaceTabBarButton.actionReference(
                        "cmux-ui-test-action-\(index)",
                        title: actionTitle,
                        icon: .symbol("circle.fill"),
                        tooltip: actionTitle
                    )
                }
                workspace.applySurfaceTabBarButtons(
                    buttons,
                    sourcePath: nil,
                    globalConfigPath: cmuxConfigStore.globalConfigPath,
                    terminalCommandSourcePaths: [:],
                    workspaceCommands: [:]
                )
            }
            if startWithHiddenSidebar {
                context.sidebarState.isVisible = false
            }
            if showRightSidebar {
                guard let fileExplorerState = context.fileExplorerState else {
                    self.writeBonsplitTabDragUITestData(["setupError": "Missing right sidebar state"])
                    return
                }
                fileExplorerState.mode = .files
                fileExplorerState.setVisible(true)
            }
            self.writeBonsplitTabDragUITestData([
                "ready": "1",
                "sidebarVisible": startWithHiddenSidebar ? "0" : "1",
                "rightSidebarVisible": context.fileExplorerState?.isVisible == true ? "1" : "0",
                "workspaceId": workspace.id.uuidString,
                "workspaceTitle": workspaceTitle,
                "alphaTitle": alphaTitle,
                "betaTitle": betaTitle,
                "alphaPanelId": alphaPanelId.uuidString,
                "betaPanelId": betaPanelId.uuidString,
            ])
            self.startBonsplitTabDragUITestRecorder(
                workspaceId: workspace.id,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self != nil else { return }
            runSetupWhenWindowReady()
        }
    }

    private func setupTerminalViewportUITestIfNeeded() {
        guard !didSetupTerminalViewportUITest else { return }
        let env = ProcessInfo.processInfo.environment
        guard TerminalViewportUITestRecorder.isEnabled(environment: env) else { return }
        didSetupTerminalViewportUITest = true

        terminalViewportUITestRecorder?.stop()
        terminalViewportUITestRecorder = TerminalViewportUITestRecorder(environment: env) { [weak self] in
            guard let self else { return [] }
            return Array(self.mainWindowContexts.values)
        }
        terminalViewportUITestRecorder?.start()
    }

    private func bonsplitTabDragUITestDataPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1",
              let path = env["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func startBonsplitTabDragUITestRecorder(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        bonsplitTabDragUITestRecorder?.cancel()
        bonsplitTabDragUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recordBonsplitTabDragUITestState(
                workspaceId: workspaceId,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }
        bonsplitTabDragUITestRecorder = timer
        timer.resume()
    }

    private func recordBonsplitTabDragUITestState(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        guard let tabManager else { return }
        guard let workspace = (tabManager.tabs.first { $0.id == workspaceId } ?? tabManager.selectedWorkspace ?? tabManager.tabs.first) else {
            return
        }

        let trackedPaneId = workspace.paneId(forPanelId: alphaPanelId)
            ?? workspace.paneId(forPanelId: betaPanelId)
            ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let trackedPaneId else { return }

        let titles: [String] = workspace.bonsplitController.tabs(inPane: trackedPaneId).compactMap { tab in
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { return nil }
            return workspace.panelTitle(panelId: panelId)
        }
        let selectedTitle = workspace.bonsplitController.selectedTab(inPane: trackedPaneId)
            .flatMap { workspace.panelIdFromSurfaceId($0.id) }
            .flatMap { workspace.panelTitle(panelId: $0) } ?? ""

        writeBonsplitTabDragUITestData([
            "trackedPaneId": trackedPaneId.description,
            "trackedPaneTabTitles": titles.joined(separator: "|"),
            "trackedPaneTabCount": String(titles.count),
            "trackedPaneSelectedTitle": selectedTitle,
        ])
    }

    private func writeBonsplitTabDragUITestData(_ updates: [String: String]) {
        guard let path = bonsplitTabDragUITestDataPath() else { return }
        var payload = loadBonsplitTabDragUITestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadBonsplitTabDragUITestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
    private func isGotoSplitUITestRecordingEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UI_TEST_GOTO_SPLIT_SETUP"] == "1" || env["CMUX_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1"
    }

    private func gotoSplitUITestDataPath() -> String? {
        guard isGotoSplitUITestRecordingEnabled() else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return path
    }

    private func gotoSplitFindStateSnapshot(for workspace: Workspace) -> [String: String] {
        var updates: [String: String] = [
            "focusedPaneId": workspace.bonsplitController.focusedPaneId?.description ?? ""
        ]

        if let focusedPanelId = workspace.focusedPanelId {
            updates["focusedPanelId"] = focusedPanelId.uuidString
            if let terminal = workspace.terminalPanel(for: focusedPanelId) {
                updates["focusedPanelKind"] = "terminal"
                updates["focusedTerminalFindNeedle"] = terminal.searchState?.needle ?? ""
                updates["focusedBrowserFindNeedle"] = ""
            } else if let browser = workspace.browserPanel(for: focusedPanelId) {
                updates["focusedPanelKind"] = "browser"
                updates["focusedBrowserFindNeedle"] = browser.searchState?.needle ?? ""
                updates["focusedTerminalFindNeedle"] = ""
            } else {
                updates["focusedPanelKind"] = "other"
                updates["focusedTerminalFindNeedle"] = ""
                updates["focusedBrowserFindNeedle"] = ""
            }
        } else {
            updates["focusedPanelId"] = ""
            updates["focusedPanelKind"] = "none"
            updates["focusedTerminalFindNeedle"] = ""
            updates["focusedBrowserFindNeedle"] = ""
        }

        let terminalWithFind = workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .first(where: { $0.searchState != nil })
        updates["terminalFindPanelId"] = terminalWithFind?.id.uuidString ?? ""
        updates["terminalFindNeedle"] = terminalWithFind?.searchState?.needle ?? ""
        updates["terminalFindVisible"] = terminalWithFind == nil ? "false" : "true"

        let browserWithFind = workspace.panels.values
            .compactMap { $0 as? BrowserPanel }
            .first(where: { $0.searchState != nil })
        updates["browserFindPanelId"] = browserWithFind?.id.uuidString ?? ""
        updates["browserFindNeedle"] = browserWithFind?.searchState?.needle ?? ""
        updates["browserFindSelected"] = browserWithFind?.searchState?.selected.map {
            String($0 + 1)
        } ?? ""
        updates["browserFindTotal"] = browserWithFind?.searchState?.total.map(String.init) ?? ""
        updates["browserFindVisible"] = browserWithFind == nil ? "false" : "true"

        let currentResponder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
        updates["firstResponderTerminalPanelId"] =
            cmuxOwningGhosttyView(for: currentResponder)?.terminalSurface?.id.uuidString ?? ""

        updates.merge(cmuxFindResponderSnapshot()) { _, new in new }
        return updates
    }

    private func focusWebViewForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) {
        guard let browserPanel = tab.browserPanel(for: browserPanelId) else {
            writeGotoSplitTestData([
                "webViewFocused": "false",
                "setupError": "Browser panel missing"
            ])
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
        }

        func recordFocusedState() {
            guard !resolved else { return }
            guard let panel = tab.browserPanel(for: browserPanelId) else {
                resolved = true
                cleanup()
                writeGotoSplitTestData([
                    "webViewFocused": "false",
                    "setupError": "Browser panel missing"
                ])
                return
            }

            tab.focusPanel(browserPanelId)

            guard isWebViewFocused(panel),
                  let (browserPaneId, terminalPaneId) = paneIdsForGotoSplitUITest(
                    tab: tab,
                    browserPanelId: browserPanelId
                  ) else {
                return
            }

            resolved = true
            cleanup()
            self.startGotoSplitUITestRecorder(browserPanelId: browserPanelId)
            writeGotoSplitTestData([
                "browserPanelId": browserPanelId.uuidString,
                "browserPaneId": browserPaneId.description,
                "terminalPaneId": terminalPaneId.description,
                "initialPaneCount": String(tab.bonsplitController.allPaneIds.count),
                "focusedPaneId": tab.bonsplitController.focusedPaneId?.description ?? "",
                "ghosttyGotoSplitLeftShortcut": ghosttyGotoSplitLeftShortcut?.displayString ?? "",
                "ghosttyGotoSplitRightShortcut": ghosttyGotoSplitRightShortcut?.displayString ?? "",
                "ghosttyGotoSplitUpShortcut": ghosttyGotoSplitUpShortcut?.displayString ?? "",
                "ghosttyGotoSplitDownShortcut": ghosttyGotoSplitDownShortcut?.displayString ?? "",
                "webViewFocused": "true"
            ])
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_GOTO_SPLIT_INPUT_SETUP"] == "1" {
                setupFocusedInputForGotoSplitUITest(panel: panel)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            recordFocusedState()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let surfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == browserPanelId else { return }
            recordFocusedState()
        })
        panelsCancellable = tab.panelsPublisher
            .map { _ in () }
            .sink { _ in recordFocusedState() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            if !resolved {
                cleanup()
                self.writeGotoSplitTestData([
                    "webViewFocused": "false",
                    "setupError": "Timed out waiting for WKWebView focus"
                ])
            }
        }

        recordFocusedState()
    }

    private func startGotoSplitUITestRecorder(browserPanelId: UUID) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        gotoSplitUITestRecorder?.cancel()
        gotoSplitUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recordGotoSplitUITestState(browserPanelId: browserPanelId)
        }
        gotoSplitUITestRecorder = timer
        timer.resume()
    }

    private func startGotoSplitRecordOnlyRecorder() {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        gotoSplitUITestRecorder?.cancel()
        gotoSplitUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let workspace = self.tabManager?.selectedWorkspace else { return }
                self.writeGotoSplitTestData(self.gotoSplitFindStateSnapshot(for: workspace))
            }
        }
        gotoSplitUITestRecorder = timer
        timer.resume()
    }

    private func recordGotoSplitUITestState(browserPanelId: UUID) {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let browserPanel = workspace.browserPanel(for: browserPanelId) else {
            return
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["browserPageTitle"] = browserPanel.webView.title?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updates["browserPageURL"] = browserPanel.preferredURLStringForOmnibar() ?? ""
        updates["browserFocusModeActive"] = browserPanel.isBrowserFocusModeActive ? "true" : "false"
        updates["browserFocusModeExitArmed"] = browserPanel.isBrowserFocusModeExitArmed ? "true" : "false"
        writeGotoSplitTestData(updates)
    }

    private func paneIdsForGotoSplitUITest(tab: Workspace, browserPanelId: UUID) -> (browser: PaneID, terminal: PaneID)? {
        let paneIds = tab.bonsplitController.allPaneIds
        guard paneIds.count >= 2 else { return nil }

        var browserPane: PaneID?
        var terminalPane: PaneID?
        for paneId in paneIds {
            guard let selected = tab.bonsplitController.selectedTab(inPane: paneId),
                  let panelId = tab.panelIdFromSurfaceId(selected.id) else { continue }
            if panelId == browserPanelId {
                browserPane = paneId
            } else if terminalPane == nil {
                terminalPane = paneId
            }
        }

        guard let browserPane, let terminalPane else { return nil }
        return (browserPane, terminalPane)
    }

    private func installGotoSplitUITestFocusObserversIfNeeded() {
        guard gotoSplitUITestObservers.isEmpty else { return }

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserFocusAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarFocus")
            self.recordGotoSplitUITestActiveElement(panelId: panelId, keyPrefix: "addressBarFocus")
        })

        gotoSplitUITestObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidExitAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.recordGotoSplitUITestWebViewFocus(panelId: panelId, key: "webViewFocusedAfterAddressBarExit")
            self.recordGotoSplitUITestActiveElement(panelId: panelId, keyPrefix: "addressBarExit")
        })

    }

    private func recordGotoSplitUITestWebViewFocus(panelId: UUID, key: String) {
        guard let tabManager,
              let tab = tabManager.selectedWorkspace,
              let panel = tab.browserPanel(for: panelId) else {
            return
        }

        guard key.contains("Exit") else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.writeGotoSplitTestData([
                    key: self.isWebViewFocused(panel) ? "true" : "false",
                    "\(key)PanelId": panelId.uuidString
                ])
            }
            return
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
            panelsCancellable = nil
        }

        @MainActor
        func finish(with focused: Bool) {
            guard !resolved else { return }
            resolved = true
            cleanup()
            self.writeGotoSplitTestData([
                key: focused ? "true" : "false",
                "\(key)PanelId": panelId.uuidString
            ])
        }

        @MainActor
        func evaluate() {
            guard !resolved,
                  let currentTabManager = self.tabManager,
                  let currentTab = currentTabManager.selectedWorkspace,
                  let currentPanel = currentTab.browserPanel(for: panelId) else {
                return
            }
            guard self.isWebViewFocused(currentPanel) else { return }
            finish(with: true)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard notification.object as? WKWebView === panel.webView else { return }
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  surfaceId == panelId else { return }
            Task { @MainActor in evaluate() }
        })
        panelsCancellable = tab.panelsPublisher
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in evaluate() }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !resolved else { return }
                let focused = (self.tabManager?.selectedWorkspace?.browserPanel(for: panelId)).map(self.isWebViewFocused) ?? false
                finish(with: focused)
            }
        }
        Task { @MainActor in evaluate() }
    }

    private func setupFocusedInputForGotoSplitUITest(panel: BrowserPanel) {
        let script = """
        (() => {
          const snapshot = () => {
            const active = document.activeElement;
            return {
              focused: false,
              id: "",
              secondaryId: "",
              secondaryCenterX: -1,
              secondaryCenterY: -1,
              activeId: active && typeof active.id === "string" ? active.id : "",
              activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
              trackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true,
              trackedStateId:
                window.__cmuxAddressBarFocusState &&
                typeof window.__cmuxAddressBarFocusState.id === "string"
                  ? window.__cmuxAddressBarFocusState.id
                  : "",
              readyState: String(document.readyState || "")
            };
          };
          const seed = () => {
            const ensureInput = (id, value) => {
              const existing = document.getElementById(id);
              const input = (existing && existing.tagName && existing.tagName.toLowerCase() === "input")
                ? existing
                : (() => {
                    const created = document.createElement("input");
                    created.id = id;
                    created.type = "text";
                    created.value = value;
                    return created;
                  })();
              input.autocapitalize = "off";
              input.autocomplete = "off";
              input.spellcheck = false;
              input.style.display = "block";
              input.style.width = "100%";
              input.style.margin = "0";
              input.style.padding = "8px 10px";
              input.style.border = "1px solid #5f6368";
              input.style.borderRadius = "6px";
              input.style.boxSizing = "border-box";
              input.style.fontSize = "14px";
              input.style.fontFamily = "system-ui, -apple-system, sans-serif";
              input.style.background = "white";
              input.style.color = "black";
              return input;
            };

            let container = document.getElementById("cmux-ui-test-focus-container");
            if (!container || !container.tagName || container.tagName.toLowerCase() !== "div") {
              container = document.createElement("div");
              container.id = "cmux-ui-test-focus-container";
              document.body.appendChild(container);
            }
            container.style.position = "fixed";
            container.style.left = "24px";
            container.style.top = "24px";
            container.style.width = "min(520px, calc(100vw - 48px))";
            container.style.display = "grid";
            container.style.rowGap = "12px";
            container.style.padding = "12px";
            container.style.background = "rgba(255,255,255,0.92)";
            container.style.border = "1px solid rgba(95,99,104,0.55)";
            container.style.borderRadius = "8px";
            container.style.boxShadow = "0 2px 10px rgba(0,0,0,0.2)";
            container.style.zIndex = "2147483647";

            const input = ensureInput("cmux-ui-test-focus-input", "cmux-ui-focus-primary");
            const secondaryInput = ensureInput("cmux-ui-test-focus-input-secondary", "cmux-ui-focus-secondary");
            if (input.parentElement !== container) {
              container.appendChild(input);
            }
            if (secondaryInput.parentElement !== container) {
              container.appendChild(secondaryInput);
            }

            input.focus({ preventScroll: true });
            if (typeof input.setSelectionRange === "function") {
              const end = input.value.length;
              input.setSelectionRange(end, end);
            }

            let trackedFocusId = input.getAttribute("data-cmux-addressbar-focus-id");
            if (!trackedFocusId) {
              trackedFocusId = "cmux-ui-test-focus-input-tracked";
              input.setAttribute("data-cmux-addressbar-focus-id", trackedFocusId);
            }
            const selectionStart = typeof input.selectionStart === "number" ? input.selectionStart : null;
            const selectionEnd = typeof input.selectionEnd === "number" ? input.selectionEnd : null;
            if (
              !window.__cmuxAddressBarFocusState ||
              typeof window.__cmuxAddressBarFocusState.id !== "string" ||
              window.__cmuxAddressBarFocusState.id !== trackedFocusId
            ) {
              window.__cmuxAddressBarFocusState = { id: trackedFocusId, selectionStart, selectionEnd };
            }

            const secondaryRect = secondaryInput.getBoundingClientRect();
            const viewportWidth = Math.max(Number(window.innerWidth) || 0, 1);
            const viewportHeight = Math.max(Number(window.innerHeight) || 0, 1);
            const secondaryCenterX = Math.min(
              0.98,
              Math.max(0.02, (secondaryRect.left + (secondaryRect.width / 2)) / viewportWidth)
            );
            const secondaryCenterY = Math.min(
              0.98,
              Math.max(0.02, (secondaryRect.top + (secondaryRect.height / 2)) / viewportHeight)
            );
            const active = document.activeElement;
            return {
              focused: active === input,
              id: input.id || "",
              secondaryId: secondaryInput.id || "",
              secondaryCenterX,
              secondaryCenterY,
              activeId: active && typeof active.id === "string" ? active.id : "",
              activeTag: active && active.tagName ? active.tagName.toLowerCase() : "",
              trackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true,
              trackedStateId:
                window.__cmuxAddressBarFocusState &&
                typeof window.__cmuxAddressBarFocusState.id === "string"
                  ? window.__cmuxAddressBarFocusState.id
                  : "",
              readyState: String(document.readyState || "")
            };
          };
          const ready = () =>
            window.__cmuxAddressBarFocusTrackerInstalled === true &&
            String(document.readyState || "") === "complete";

          if (ready()) {
            try {
              return seed();
            } catch (_) {
              return snapshot();
            }
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const maybeFinish = () => {
              if (!ready()) return;
              try {
                finish(seed());
              } catch (_) {
                finish(snapshot());
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== "function") return;
              const handler = () => maybeFinish();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };
            try {
              observer = new MutationObserver(() => maybeFinish());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}
            addListener(document, "readystatechange", true);
            addListener(window, "load", true);
            const timeoutId = window.setTimeout(() => finish(snapshot()), 4000);
            cleanups.push(() => window.clearTimeout(timeoutId));
            maybeFinish();
          });
        })();
        """

        panel.webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            let payload = result as? [String: Any]
            let focused = (payload?["focused"] as? Bool) ?? false
            let inputId = (payload?["id"] as? String) ?? ""
            let secondaryInputId = (payload?["secondaryId"] as? String) ?? ""
            let secondaryCenterX = (payload?["secondaryCenterX"] as? NSNumber)?.doubleValue ?? -1
            let secondaryCenterY = (payload?["secondaryCenterY"] as? NSNumber)?.doubleValue ?? -1
            let activeId = (payload?["activeId"] as? String) ?? ""
            let trackerInstalled = (payload?["trackerInstalled"] as? Bool) ?? false
            let trackedStateId = (payload?["trackedStateId"] as? String) ?? ""
            let readyState = (payload?["readyState"] as? String) ?? ""
            var secondaryClickOffsetX = -1.0
            var secondaryClickOffsetY = -1.0
            if let window = panel.webView.window {
                let webFrame = panel.webView.convert(panel.webView.bounds, to: nil)
                let contentHeight = Double(window.contentView?.bounds.height ?? 0)
                if webFrame.width > 1,
                   webFrame.height > 1,
                   contentHeight > 1,
                   secondaryCenterX > 0,
                   secondaryCenterX < 1,
                   secondaryCenterY > 0,
                   secondaryCenterY < 1 {
                    let xInContent = Double(webFrame.minX) + (secondaryCenterX * Double(webFrame.width))
                    let yFromTopInWeb = secondaryCenterY * Double(webFrame.height)
                    let yInContent = Double(webFrame.maxY) - yFromTopInWeb
                    let yFromTopInContent = contentHeight - yInContent
                    let titlebarHeight = max(0, Double(window.frame.height) - contentHeight)
                    secondaryClickOffsetX = xInContent
                    secondaryClickOffsetY = titlebarHeight + yFromTopInContent
                }
            }
            if focused,
               !inputId.isEmpty,
               !secondaryInputId.isEmpty,
               inputId == activeId,
               trackerInstalled,
               !trackedStateId.isEmpty,
               secondaryCenterX > 0,
               secondaryCenterX < 1,
               secondaryCenterY > 0,
               secondaryCenterY < 1,
               secondaryClickOffsetX > 0,
               secondaryClickOffsetY > 0 {
                self.writeGotoSplitTestData([
                    "webInputFocusSeeded": "true",
                    "webInputFocusElementId": inputId,
                    "webInputFocusSecondaryElementId": secondaryInputId,
                    "webInputFocusSecondaryCenterX": "\(secondaryCenterX)",
                    "webInputFocusSecondaryCenterY": "\(secondaryCenterY)",
                    "webInputFocusSecondaryClickOffsetX": "\(secondaryClickOffsetX)",
                    "webInputFocusSecondaryClickOffsetY": "\(secondaryClickOffsetY)",
                    "webInputFocusActiveElementId": activeId,
                    "webInputFocusTrackerInstalled": trackerInstalled ? "true" : "false",
                    "webInputFocusTrackedStateId": trackedStateId,
                    "webInputFocusReadyState": readyState
                ])
                return
            }
            self.writeGotoSplitTestData([
                "webInputFocusSeeded": "false",
                "setupError": "Timed out focusing page input for omnibar restore test"
            ])
        }
    }

    private func recordGotoSplitUITestActiveElement(panelId: UUID, keyPrefix: String) {
        guard let tabManager,
              let tab = tabManager.selectedWorkspace,
              let panel = tab.browserPanel(for: panelId) else {
            return
        }

        let expectedInputId = keyPrefix == "addressBarExit" ? gotoSplitUITestExpectedInputId() : nil
        let capture: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.evaluateGotoSplitUITestActiveElement(
                panel: panel,
                awaitingInputId: expectedInputId
            ) { snapshot in
                self.writeGotoSplitTestData([
                    "\(keyPrefix)PanelId": panelId.uuidString,
                    "\(keyPrefix)ActiveElementId": snapshot["id"] ?? "",
                    "\(keyPrefix)ActiveElementTag": snapshot["tag"] ?? "",
                    "\(keyPrefix)ActiveElementType": snapshot["type"] ?? "",
                    "\(keyPrefix)ActiveElementEditable": snapshot["editable"] ?? "false",
                    "\(keyPrefix)TrackedFocusStateId": snapshot["trackedFocusStateId"] ?? "",
                    "\(keyPrefix)FocusTrackerInstalled": snapshot["focusTrackerInstalled"] ?? "false"
                ])
            }
        }

        if expectedInputId == nil {
            DispatchQueue.main.async {
                Task { @MainActor in capture() }
            }
        } else {
            Task { @MainActor in capture() }
        }
    }

    private func evaluateGotoSplitUITestActiveElement(
        panel: BrowserPanel,
        awaitingInputId: String? = nil,
        completion: @escaping ([String: String]) -> Void
    ) {
        let expectedInputIdLiteral = awaitingInputId?.javaScriptStringLiteral ?? "null"
        let script = """
        (() => {
          const expectedInputId = \(expectedInputIdLiteral);
          const snapshot = () => {
            try {
              const active = document.activeElement;
              if (!active) {
                return {
                  id: "",
                  tag: "",
                  type: "",
                  editable: "false",
                  trackedFocusStateId: "",
                  focusTrackerInstalled: window.__cmuxAddressBarFocusTrackerInstalled === true ? "true" : "false"
                };
              }
              const tag = (active.tagName || "").toLowerCase();
              const type = (active.type || "").toLowerCase();
              const editable =
                !!active.isContentEditable ||
                tag === "textarea" ||
                (tag === "input" && type !== "hidden");
              return {
                id: typeof active.id === "string" ? active.id : "",
                tag,
                type,
                editable: editable ? "true" : "false",
                trackedFocusStateId:
                  window.__cmuxAddressBarFocusState &&
                  typeof window.__cmuxAddressBarFocusState.id === "string"
                    ? window.__cmuxAddressBarFocusState.id
                    : "",
                focusTrackerInstalled:
                  window.__cmuxAddressBarFocusTrackerInstalled === true ? "true" : "false"
              };
            } catch (_) {
              return {
                id: "",
                tag: "",
                type: "",
                editable: "false",
                trackedFocusStateId: "",
                focusTrackerInstalled: "false"
              };
            }
          };
          const matchesExpectation = (state) =>
            !expectedInputId || (typeof expectedInputId === "string" && state.id === expectedInputId);

          const initial = snapshot();
          if (matchesExpectation(initial)) {
            return initial;
          }

          return new Promise((resolve) => {
            let finished = false;
            let observer = null;
            const cleanups = [];
            const finish = (value) => {
              if (finished) return;
              finished = true;
              if (observer) observer.disconnect();
              for (const cleanup of cleanups) {
                try { cleanup(); } catch (_) {}
              }
              resolve(value);
            };
            const maybeFinish = () => {
              const state = snapshot();
              if (matchesExpectation(state)) {
                finish(state);
              }
            };
            const addListener = (target, eventName, options) => {
              if (!target || typeof target.addEventListener !== "function") return;
              const handler = () => maybeFinish();
              target.addEventListener(eventName, handler, options);
              cleanups.push(() => target.removeEventListener(eventName, handler, options));
            };
            try {
              observer = new MutationObserver(() => maybeFinish());
              observer.observe(document.documentElement || document, {
                childList: true,
                subtree: true,
                attributes: true,
                characterData: true
              });
            } catch (_) {}
            addListener(document, "focusin", true);
            addListener(document, "focusout", true);
            addListener(document, "selectionchange", true);
            addListener(document, "readystatechange", true);
            addListener(window, "load", true);
            const timeoutId = window.setTimeout(() => finish(snapshot()), 1500);
            cleanups.push(() => window.clearTimeout(timeoutId));
            maybeFinish();
          });
        })();
        """

        panel.webView.evaluateJavaScript(script) { result, _ in
            let payload = result as? [String: Any]
            completion([
                "id": (payload?["id"] as? String) ?? "",
                "tag": (payload?["tag"] as? String) ?? "",
                "type": (payload?["type"] as? String) ?? "",
                "editable": (payload?["editable"] as? String) ?? "false",
                "trackedFocusStateId": (payload?["trackedFocusStateId"] as? String) ?? "",
                "focusTrackerInstalled": (payload?["focusTrackerInstalled"] as? String) ?? "false"
            ])
        }
    }

    private func gotoSplitUITestExpectedInputId() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return loadGotoSplitTestData(at: path)["webInputFocusElementId"]
    }

    private func recordGotoSplitMoveIfNeeded(direction: NavigationDirection) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let tabManager, let workspace = tabManager.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["lastMoveDirection"] = directionValue
        writeGotoSplitTestData(updates)
    }

    private func recordGotoSplitSplitIfNeeded(direction: SplitDirection) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["lastSplitDirection"] = directionValue
        updates["paneCountAfterSplit"] = String(workspace.bonsplitController.allPaneIds.count)
        writeGotoSplitTestData(updates)
    }

    private func recordGotoSplitZoomIfNeeded(tabManager: TabManager? = nil) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let workspace = (tabManager ?? self.tabManager)?.selectedWorkspace else { return }

        func snapshot(for workspace: Workspace) -> ([String: String], Bool) {
            let browserPanel = workspace.panels.values.compactMap { $0 as? BrowserPanel }.first
            let otherTerminal = workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
            let browserSnapshot = browserPanel.flatMap { BrowserWindowPortalRegistry.debugSnapshot(for: $0.webView) }

            var updates = self.gotoSplitFindStateSnapshot(for: workspace)
            updates["splitZoomedAfterToggle"] = workspace.bonsplitController.isSplitZoomed ? "true" : "false"
            updates["zoomedPaneIdAfterToggle"] = workspace.bonsplitController.zoomedPaneId?.description ?? ""
            updates["browserPanelIdAfterToggle"] = browserPanel?.id.uuidString ?? ""
            updates["browserContainerHiddenAfterToggle"] = browserSnapshot.map { $0.containerHidden ? "true" : "false" } ?? ""
            updates["browserVisibleFlagAfterToggle"] = browserSnapshot.map { $0.visibleInUI ? "true" : "false" } ?? ""
            updates["browserFrameAfterToggle"] = browserSnapshot.map {
                String(
                    format: "%.1f,%.1f %.1fx%.1f",
                    $0.frameInWindow.origin.x,
                    $0.frameInWindow.origin.y,
                    $0.frameInWindow.size.width,
                    $0.frameInWindow.size.height
                )
            } ?? ""
            updates["otherTerminalPanelIdAfterToggle"] = otherTerminal?.id.uuidString ?? ""
            updates["otherTerminalHostHiddenAfterToggle"] = otherTerminal.map { $0.hostedView.isHidden ? "true" : "false" } ?? ""
            updates["otherTerminalVisibleFlagAfterToggle"] = otherTerminal.map { $0.hostedView.debugPortalVisibleInUI ? "true" : "false" } ?? ""
            updates["otherTerminalFrameAfterToggle"] = otherTerminal.map {
                let frame = $0.hostedView.debugPortalFrameInWindow
                return String(
                    format: "%.1f,%.1f %.1fx%.1f",
                    frame.origin.x,
                    frame.origin.y,
                    frame.size.width,
                    frame.size.height
                )
            } ?? ""

            let settled: Bool = {
                if workspace.bonsplitController.isSplitZoomed {
                    if let focusedPanelId = workspace.focusedPanelId,
                       workspace.terminalPanel(for: focusedPanelId) != nil {
                        guard let browserSnapshot else { return false }
                        return browserSnapshot.containerHidden && !browserSnapshot.visibleInUI
                    }
                    guard let otherTerminal else { return true }
                    return otherTerminal.hostedView.isHidden && !otherTerminal.hostedView.debugPortalVisibleInUI
                }
                let browserRestored = browserSnapshot.map { !$0.containerHidden && $0.visibleInUI } ?? true
                let terminalRestored = otherTerminal.map {
                    !$0.hostedView.isHidden && $0.hostedView.debugPortalVisibleInUI
                } ?? true
                return browserRestored && terminalRestored
            }()

            return (updates, settled)
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
            panelsCancellable = nil
        }

        @MainActor
        func finish(with updates: [String: String]) {
            guard !resolved else { return }
            resolved = true
            cleanup()
            self.writeGotoSplitTestData(updates)
        }

        @MainActor
        func evaluate() {
            guard !resolved, let currentWorkspace = (tabManager ?? self.tabManager)?.selectedWorkspace else { return }
            let (updates, settled) = snapshot(for: currentWorkspace)
            guard settled else { return }
            finish(with: updates)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        panelsCancellable = workspace.panelsPublisher
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in evaluate() }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !resolved, let currentWorkspace = (tabManager ?? self.tabManager)?.selectedWorkspace else { return }
                finish(with: snapshot(for: currentWorkspace).0)
            }
        }
        Task { @MainActor in evaluate() }
    }

    private func writeGotoSplitTestData(_ updates: [String: String]) {
        guard let path = gotoSplitUITestDataPath() else { return }
        var payload = loadGotoSplitTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadGotoSplitTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    private func setupMultiWindowNotificationsUITestIfNeeded() {
        guard !didSetupMultiWindowNotificationsUITest else { return }
        didSetupMultiWindowNotificationsUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        try? FileManager.default.removeItem(atPath: path)

        func waitForContexts(minCount: Int, _ completion: @escaping () -> Void) {
            let isReady = {
                self.mainWindowContexts.count >= minCount &&
                    self.mainWindowContexts.values.allSatisfy { $0.window != nil }
            }
            guard !isReady() else {
                completion()
                return
            }

            var resolved = false
            var observer: NSObjectProtocol?
            let finish = {
                guard !resolved else { return }
                resolved = true
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                completion()
            }
            observer = NotificationCenter.default.addObserver(
                forName: .mainWindowContextsDidChange,
                object: self,
                queue: .main
            ) { _ in
                if isReady() {
                    finish()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                if isReady() {
                    finish()
                } else if let observer, !resolved {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        func waitForSurfaceId(
            on tabManager: TabManager,
            tabId: UUID,
            timeout: TimeInterval = 8.0,
            _ completion: @escaping (UUID) -> Void
        ) {
            func resolvedSurfaceId() -> UUID? {
                if let surfaceId = tabManager.focusedPanelId(for: tabId) {
                    return surfaceId
                }

                guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                    return nil
                }

                if let terminalPanelId = workspace.focusedTerminalPanel?.id {
                    return terminalPanelId
                }

                if let terminalPanelId = workspace.terminalPanelForConfigInheritance()?.id {
                    return terminalPanelId
                }

                return workspace.panels.values
                    .compactMap { ($0 as? TerminalPanel)?.id }
                    .sorted(by: { $0.uuidString < $1.uuidString })
                    .first
            }

            if let surfaceId = resolvedSurfaceId() {
                completion(surfaceId)
                return
            }

            var resolved = false
            var focusObserver: NSObjectProtocol?
            var surfaceReadyObserver: NSObjectProtocol?
            var tabsCancellable: AnyCancellable?
            var panelsCancellable: AnyCancellable?
            var observedWorkspaceId: UUID?

            func cleanup() {
                if let focusObserver {
                    NotificationCenter.default.removeObserver(focusObserver)
                }
                if let surfaceReadyObserver {
                    NotificationCenter.default.removeObserver(surfaceReadyObserver)
                }
                tabsCancellable?.cancel()
                panelsCancellable?.cancel()
            }

            func attemptResolve() {
                guard !resolved else { return }
                if let workspace = tabManager.tabs.first(where: { $0.id == tabId }),
                   observedWorkspaceId != workspace.id {
                    observedWorkspaceId = workspace.id
                    panelsCancellable?.cancel()
                    panelsCancellable = workspace.panelsPublisher
                        .map { _ in () }
                        .sink { _ in attemptResolve() }
                }
                if let surfaceId = resolvedSurfaceId() {
                    resolved = true
                    cleanup()
                    completion(surfaceId)
                }
            }

            tabsCancellable = tabManager.tabsPublisher
                .map { _ in () }
                .sink { _ in attemptResolve() }
            focusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tabId else { return }
                attemptResolve()
            }
            surfaceReadyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                      workspaceId == tabId else { return }
                attemptResolve()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !resolved {
                    cleanup()
                }
            }
            attemptResolve()
        }

        waitForContexts(minCount: 1) { [weak self] in
            guard let self else { return }
            guard let window1 = self.mainWindowContexts.values.first else { return }
            guard let tabId1 = window1.tabManager.selectedTabId ?? window1.tabManager.tabs.first?.id else { return }

            // Create a second main terminal window.
            self.openNewMainWindow(nil)

            waitForContexts(minCount: 2) { [weak self] in
                guard let self else { return }
                let contexts = Array(self.mainWindowContexts.values)
                guard let window2 = contexts.first(where: { $0.windowId != window1.windowId }) else { return }
                guard let tabId2 = window2.tabManager.selectedTabId ?? window2.tabManager.tabs.first?.id else { return }
                waitForSurfaceId(on: window1.tabManager, tabId: tabId1) { [weak self] surfaceId1 in
                    guard let self else { return }
                    waitForSurfaceId(on: window2.tabManager, tabId: tabId2) { [weak self] surfaceId2 in
                    guard let self else { return }
                    guard let store = self.notificationStore else { return }

                    // Ensure the target window is currently showing the Notifications overlay,
                    // so opening a notification must switch it back to the terminal UI.
                    window2.sidebarSelectionState.selection = .notifications

                    // Create notifications for both windows. Ensure W2 isn't suppressed just because it's focused.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    store.addNotification(tabId: tabId2, surfaceId: nil, title: "W2", subtitle: "multiwindow", body: "")
                    AppFocusState.overrideIsFocused = prevOverride

                    // Insert after W2 so it becomes "latest unread" (first in list).
                    store.addNotification(tabId: tabId1, surfaceId: nil, title: "W1", subtitle: "multiwindow", body: "")

                    let notif1 = store.notifications.first(where: { $0.tabId == tabId1 && $0.title == "W1" })
                    let notif2 = store.notifications.first(where: { $0.tabId == tabId2 && $0.title == "W2" })

                    self.writeMultiWindowNotificationTestData([
                        "window1Id": window1.windowId.uuidString,
                        "window2Id": window2.windowId.uuidString,
                        "window2InitialSidebarSelection": "notifications",
                        "tabId1": tabId1.uuidString,
                        "tabId2": tabId2.uuidString,
                        "surfaceId1": surfaceId1.uuidString,
                        "surfaceId2": surfaceId2.uuidString,
                        "notifId1": notif1?.id.uuidString ?? "",
                        "notifId2": notif2?.id.uuidString ?? "",
                        "expectedLatestWindowId": window1.windowId.uuidString,
                        "expectedLatestTabId": tabId1.uuidString,
                    ], at: path)
                    self.prepareMultiWindowNotificationSourceTerminalIfNeeded(
                        at: path,
                        windowId: window1.windowId,
                        tabManager: window1.tabManager,
                        tabId: tabId1,
                        surfaceId: surfaceId1
                    )
                    self.publishMultiWindowNotificationSocketStateIfNeeded(
                        at: path,
                        window1Id: window1.windowId,
                        window2Id: window2.windowId
                    )
                }
                }
            }
        }
    }

    private func prepareMultiWindowNotificationSourceTerminalIfNeeded(
        at path: String,
        windowId: UUID,
        tabManager: TabManager,
        tabId: UUID,
        surfaceId: UUID
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_NOTIFY_SOURCE_TERMINAL_READY"] == "1" else { return }

        writeMultiWindowNotificationTestData([
            "sourceTerminalReady": "pending",
            "sourceTerminalFocusFailure": "",
        ], at: path)

        let deadline = Date().addingTimeInterval(8.0)

        func publish(ready: Bool, failure: String = "") {
            writeMultiWindowNotificationTestData([
                "sourceTerminalReady": ready ? "1" : "0",
                "sourceTerminalFocusFailure": failure,
            ], at: path)
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var selectedTabCancellable: AnyCancellable?
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            selectedTabCancellable?.cancel()
            panelsCancellable?.cancel()
        }

        func attemptFocus() {
            guard !resolved else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                resolved = true
                cleanup()
                publish(ready: false, failure: "workspace_missing")
                return
            }
            panelsCancellable?.cancel()
            panelsCancellable = workspace.panelsPublisher
                .map { _ in () }
                .sink { _ in attemptFocus() }
            guard let terminalPanel = workspace.terminalPanel(for: surfaceId) else {
                resolved = true
                cleanup()
                publish(ready: false, failure: "terminal_missing")
                return
            }

            let isWindowFrontmost = {
                guard let window = self.mainWindow(for: windowId) else { return false }
                return NSApp.keyWindow === window || NSApp.mainWindow === window
            }()
            if isWindowFrontmost && terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                resolved = true
                cleanup()
                publish(ready: true)
                return
            }

            guard Date() < deadline else {
                resolved = true
                cleanup()
                publish(
                    ready: false,
                    failure: isWindowFrontmost ? "terminal_not_first_responder" : "window_not_frontmost"
                )
                return
            }

            _ = self.focusMainWindow(windowId: windowId)
            if let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
                tabManager.selectTab(tab)
                tabManager.focusSurface(tabId: tabId, surfaceId: surfaceId)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: self,
            queue: .main
        ) { _ in
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  candidateTabId == tabId,
                  candidateSurfaceId == surfaceId else { return }
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  candidateTabId == tabId,
                  candidateSurfaceId == surfaceId else { return }
            attemptFocus()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                  workspaceId == tabId,
                  readySurfaceId == surfaceId else { return }
            attemptFocus()
        })
        selectedTabCancellable = tabManager.selectedTabIdPublisher
            .map { _ in () }
            .sink { _ in attemptFocus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if !resolved {
                attemptFocus()
            }
        }
        attemptFocus()
    }

    private func runMultiWindowWindowRouteCLIIfNeeded(
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

        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
        guard health.socketPathExists else {
            writeMultiWindowNotificationTestData([
                "windowRouteStatus": "0",
                "windowRouteFailure": "socket_not_ready",
            ], at: path)
            return
        }

        let router = MultiWindowRouter(
            cliURL: cliURL,
            socketPath: socketPath,
            environment: processEnv
        )
        // Inherits MainActor; each await runs the CLI off-main and the final
        // write lands back on main, matching the legacy queue hops.
        Task(priority: .userInitiated) { [weak self] in
            let create = await router.routeCapturingLaunchFailure(
                arguments: [
                    "new-workspace",
                    "--window",
                    window2Id.uuidString,
                    "--name",
                    title,
                    "--focus",
                    "false",
                ]
            )
            let window2List = await router.routeCapturingLaunchFailure(
                arguments: [
                    "--json",
                    "--id-format",
                    "uuids",
                    "list-workspaces",
                    "--window",
                    window2Id.uuidString,
                ]
            )
            let window1List = await router.routeCapturingLaunchFailure(
                arguments: [
                    "--json",
                    "--id-format",
                    "uuids",
                    "list-workspaces",
                    "--window",
                    window1Id.uuidString,
                ]
            )

            self?.writeMultiWindowNotificationTestData([
                "windowRouteStatus": "1",
                "windowRouteCreateStatus": String(create.terminationStatus),
                "windowRouteCreateStdout": create.stdout,
                "windowRouteCreateStderr": create.stderr,
                "windowRouteWindow2Status": String(window2List.terminationStatus),
                "windowRouteWindow2Stdout": window2List.stdout,
                "windowRouteWindow2Stderr": window2List.stderr,
                "windowRouteWindow1Status": String(window1List.terminationStatus),
                "windowRouteWindow1Stdout": window1List.stdout,
                "windowRouteWindow1Stderr": window1List.stderr,
            ], at: path)
        }
    }

    private func publishMultiWindowNotificationSocketStateIfNeeded(
        at path: String,
        window1Id: UUID? = nil,
        window2Id: UUID? = nil
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        guard let config = socketListenerConfigurationIfEnabled() else {
            writeMultiWindowNotificationTestData([
                "socketExpectedPath": env["CMUX_SOCKET_PATH"] ?? "",
                "socketMode": "off",
                "socketReady": "0",
                "socketPingResponse": "",
                "socketIsRunning": "0",
                "socketAcceptLoopAlive": "0",
                "socketPathMatches": "0",
                "socketPathExists": "0",
                "socketPathOwnedByListener": "0",
                "socketFailureSignals": "socket_disabled",
            ], at: path)
            return
        }

        writeMultiWindowNotificationTestData([
            "socketExpectedPath": config.path,
            "socketMode": config.mode.rawValue,
            "socketReady": "pending",
            "socketPingResponse": "",
        ], at: path)

        let socketPath = config.path
        let socketMode = config.mode.rawValue
        var observer: NSObjectProtocol?
        var timeoutWorkItem: DispatchWorkItem?

        func publishCurrentState(isTimedOut: Bool) {
            let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
            let dataPath = path
            let socketTransport = self.socketTransport
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let pingResponse = health.isHealthy
                    ? socketTransport.probeCommand("ping", at: socketPath, timeout: 1.0)
                    : nil
                let isReady = health.isHealthy && pingResponse == "PONG"
                let failureSignals = {
                    var signals = health.failureSignals
                    if health.isHealthy && pingResponse != "PONG" {
                        signals.append("ping_timeout")
                    }
                    return signals.joined(separator: ",")
                }()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.writeMultiWindowNotificationTestData([
                        "socketExpectedPath": socketPath,
                        "socketMode": socketMode,
                        "socketReady": isReady ? "1" : (isTimedOut ? "0" : "pending"),
                        "socketPingResponse": pingResponse ?? "",
                        "socketIsRunning": health.isRunning ? "1" : "0",
                        "socketAcceptLoopAlive": health.acceptLoopAlive ? "1" : "0",
                        "socketPathMatches": health.socketPathMatches ? "1" : "0",
                        "socketPathExists": health.socketPathExists ? "1" : "0",
                        "socketPathOwnedByListener": health.socketPathOwnedByListener ? "1" : "0",
                        "socketFailureSignals": failureSignals,
                    ], at: dataPath)
                    if isReady, let window1Id, let window2Id {
                        self.runMultiWindowWindowRouteCLIIfNeeded(
                            at: dataPath,
                            window1Id: window1Id,
                            window2Id: window2Id,
                            socketPath: socketPath
                        )
                    }
                    guard isReady || isTimedOut else { return }
                    timeoutWorkItem?.cancel()
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                }
            }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .socketListenerDidStart,
            object: TerminalController.shared,
            queue: .main
        ) { notification in
            let startedPath = notification.userInfo?["path"] as? String
            guard startedPath == socketPath else { return }
            publishCurrentState(isTimedOut: false)
        }

        let timeout = DispatchWorkItem {
            publishCurrentState(isTimedOut: true)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: timeout)

        restartSocketListenerIfEnabled(source: "uiTest.multiWindowNotifications.setup")
        publishCurrentState(isTimedOut: false)
    }

    private func writeMultiWindowNotificationTestData(_ updates: [String: String], at path: String) {
        var payload = loadMultiWindowNotificationTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadMultiWindowNotificationTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    func recordMultiWindowNotificationFocusIfNeeded(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        sidebarSelection: SidebarSelection
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }
        let sidebarSelectionString: String = {
            switch sidebarSelection {
            case .tabs: return "tabs"
            case .notifications: return "notifications"
            }
        }()
        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "focusedWindowId": windowId.uuidString,
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId?.uuidString ?? "",
            "focusedSidebarSelection": sidebarSelectionString,
        ], at: path)
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
                        "monitor.keyDown: \(NSWindow.keyDescription(event)) fr=\(frType) addrBarId=\(self.browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil") \(self.debugShortcutRouteSnapshot(event: event))"
                    )
                }
                if let probeKind = self.developerToolsShortcutProbeKind(event: event) {
                    self.logDeveloperToolsShortcutSnapshot(phase: "monitor.pre.\(probeKind)", event: event)
                }
                preludeMs = (ProcessInfo.processInfo.systemUptime - preludeStart) * 1000.0
                let shortcutTimingStart = CmuxTypingTiming.start()
#endif
                let shortcutStart = ProcessInfo.processInfo.systemUptime
                let handledByShortcut = cmuxCloseFocusedTerminalFindForEscape(event: event, appDelegate: self) || self.handleCustomShortcut(event: event)
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
            guard action != .showHideAllWindows && action != .globalSearch && action.allowsChordShortcut else { return false }
            guard !action.isBrowserContentShortcut else { return false }
            return KeyboardShortcutSettings.shortcut(for: action).hasChord
        }
    }

    func clearConfiguredShortcutChordState() {
        pendingConfiguredShortcutChord = nil
        activeConfiguredShortcutChordPrefixForCurrentEvent = nil
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
        for context in mainWindowContexts.values {
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
            self?.refreshGhosttyGotoSplitShortcuts()
        }
    }

    private func installGlobalFontMagnificationObserver() {
        guard globalFontMagnificationObserver == nil else { return }
        globalFontMagnificationObserver = NotificationCenter.default.addObserver(
            forName: GlobalFontMagnification.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            GhosttyConfig.invalidateLoadCache()
            MainActor.assumeIsolated {
                self?.reloadConfiguration(
                    source: "globalFontMagnificationDidChange",
                    reloadSettingsFromFile: false
                )
            }
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
        if let keyEquivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    private func reloadConfigurationMenuItem(in menu: NSMenu) -> NSMenuItem? {
        if let identifiedItem = menu.items.first(where: { $0.identifier == Self.reloadConfigurationMenuItemIdentifier }) {
            return identifiedItem
        }

        let reloadConfigurationTitle = String(
            localized: "menu.app.reloadConfiguration",
            defaultValue: "Reload Configuration"
        )
        return menu.items.first(where: { $0.title == reloadConfigurationTitle })
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
        mainWindowContexts.values.compactMap { $0.cmuxConfigStore }
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
        let tag: GhosttyTriggerInput.Tag
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            tag = .physical(GhosttyTriggerPhysicalKey(ghosttyPhysicalKey: trigger.key.physical))
        case GHOSTTY_TRIGGER_UNICODE:
            tag = .unicode(UnicodeScalar(trigger.key.unicode))
        case GHOSTTY_TRIGGER_CATCH_ALL:
            tag = .catchAll
        default:
            return nil
        }

        let input = GhosttyTriggerInput(
            tag: tag,
            modifiers: GhosttyModifierMask(rawValue: trigger.mods.rawValue)
        )
        guard let shortcut = GhosttyTriggerShortcut(decoding: input) else { return nil }
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

        presentQuitConfirmationAlert(ownsTerminateRequest: false) { [weak self] response, suppressionState in
            if suppressionState == .on {
                QuitConfirmationStore(defaults: .standard).setEnabled(false)
            }

            if response == .alertFirstButtonReturn {
                // Mark as confirmed so applicationShouldTerminate does not show a
                // second alert when NSApp.terminate re-enters the delegate callback.
                self?.isQuitWarningConfirmed = true
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
        if let pendingConfiguredShortcutChord,
           pendingConfiguredShortcutChord.windowNumber == configuredShortcutEventWindowNumber {
            activeConfiguredShortcutChordPrefixForCurrentEvent = pendingConfiguredShortcutChord.firstStroke
        } else {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
        }
        pendingConfiguredShortcutChord = nil
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
            String(localized: "dialog.closePane.title", defaultValue: "Close pane?"),
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
        let commandPaletteShortcutWindow = shouldHandleCommandPaletteShortcutEvent(
            event,
            paletteWindow: commandPaletteTargetWindow
        ) ? commandPaletteTargetWindow : nil
        let commandPaletteVisibleInTargetWindow = commandPaletteShortcutWindow.map {
            isCommandPaletteVisible(for: $0)
        } ?? false
        let commandPalettePendingOpenInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPalettePendingOpen(for: $0)
        } ?? false
        let commandPaletteOverlayVisibleInTargetWindow = commandPaletteTargetWindow.map {
            isCommandPaletteOverlayPresented(in: $0)
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

        if shouldRouteCommandPaletteSelectionNavigation(
            delta: paletteSelectionDelta,
            isInteractive: commandPaletteInteractiveInTargetWindow,
            usesInlineTextHandling: paletteUsesInlineTextHandling
        ),
           let delta = paletteSelectionDelta,
           let paletteWindow = commandPaletteShortcutWindow {
            NotificationCenter.default.post(name: .commandPaletteMoveSelection, object: paletteWindow, userInfo: ["delta": delta])
            return true
        }

        let shouldRouteConfiguredPaletteSelection = commandPaletteShortcutWindow != nil && shouldRouteCommandPaletteSelectionNavigation(delta: 1, isInteractive: commandPaletteInteractiveInTargetWindow, usesInlineTextHandling: paletteUsesInlineTextHandling)

        if shouldRouteConfiguredPaletteSelection, let paletteWindow = commandPaletteShortcutWindow {
            for (action, delta) in [(KeyboardShortcutSettings.Action.commandPaletteNext, 1), (.commandPalettePrevious, -1)] {
                guard KeyboardShortcutSettings.shortcut(for: action).hasChord, matchConfiguredShortcut(event: event, action: action) else { continue }
                NotificationCenter.default.post(name: .commandPaletteMoveSelection, object: paletteWindow, userInfo: ["delta": delta])
                return true
            }
        }

        if commandPaletteInteractiveInTargetWindow,
           let paletteWindow = commandPaletteShortcutWindow {
            let paletteFieldEditorHasMarkedText = commandPaletteFieldEditorHasMarkedText(in: paletteWindow)
            let paletteSnapshot = mainWindowId(for: paletteWindow).map(commandPaletteSnapshot(windowId:)) ?? .empty
            let paletteUsesInlineReturnHandling = paletteUsesInlineTextHandling
            if isPlainEscape {
                if paletteFieldEditorHasMarkedText {
                    return false
                }
                NotificationCenter.default.post(name: .commandPaletteDismissRequested, object: paletteWindow)
                return true
            }

            let shouldSubmitPalette = shouldSubmitCommandPaletteWithReturn(
                keyCode: event.keyCode,
                flags: event.modifierFlags,
                mode: paletteSnapshot.mode
            )
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

        // Guard against stale browserAddressBarFocusedPanelId after focus transitions
        // (e.g., split that doesn't properly blur the address bar). If the first responder
        // is a terminal surface, the address bar can't be focused.
        if browserAddressBarFocusedPanelId != nil,
           cmuxOwningGhosttyView(for: shortcutRoutingKeyWindow?.firstResponder) != nil {
#if DEBUG
            let stalePanelToken = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            let firstResponderType = shortcutRoutingKeyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            cmuxDebugLog(
                "browser.focus.addressBar.staleClear panel=\(stalePanelToken) " +
                "reason=terminal_first_responder fr=\(firstResponderType)"
            )
#endif
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
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

        if shouldConsumeShortcutWhileCommandPaletteVisible(
            isCommandPaletteVisible: commandPaletteEffectiveInTargetWindow,
            normalizedFlags: normalizedFlags,
            chars: chars,
            keyCode: event.keyCode
        ) {
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
#if DEBUG
            cmuxDebugLog("handleCustomShortcut: unresolved event window context; bypassing app shortcut handling")
#endif
            return false
        }
        if handleFocusedFileExplorerOpenSelectionShortcut(
            event,
            preferredWindow: mainWindowForShortcutEvent(event) ?? resolvedShortcutEventWindow(event) ?? shortcutRoutingActiveWindow
        ) {
            return true
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
               shortcuts: configuredCmuxShortcutActions.compactMap(\.shortcut)
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

        if handleSavedLayoutShortcut(event) { return true }

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
                "rs.focus.toggle.shortcut.begin event=\(NSWindow.keyDescription(event)) " +
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
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.selectNextSurface()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .prevSurface) {
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.selectPreviousSurface()
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
                if closeFocusedDockPanelForCommand(preferredWindow: mainWindowForFocusedCloseShortcut(event: event)) { return true }
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
               let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: digit, workspaceCount: manager.tabs.count) {
#if DEBUG
                cmuxDebugLog(
                    "shortcut.action name=workspaceDigit digit=\(digit) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
                )
#endif
                manager.selectTab(at: targetIndex)
            }
            return true
        }

        // Numeric shortcuts for surfaces: focused pane in split layout,
        // workspace Canvas order in Canvas layout (9 = last).
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
        ) || (ghosttyGotoSplitLeftShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "←", arrowKeyCode: 123) } ?? false) {
            let routedTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: routedTabs, window: shortcutRoutingKeyWindow)
            routedTabs?.movePaneFocus(direction: .left)
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
        ) || (ghosttyGotoSplitRightShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "→", arrowKeyCode: 124) } ?? false) {
            let routedTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: routedTabs, window: shortcutRoutingKeyWindow)
            routedTabs?.movePaneFocus(direction: .right)
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
        ) || (ghosttyGotoSplitUpShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↑", arrowKeyCode: 126) } ?? false) {
            let routedTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: routedTabs, window: shortcutRoutingKeyWindow)
            routedTabs?.movePaneFocus(direction: .up)
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
        ) || (ghosttyGotoSplitDownShortcut.map { matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: "↓", arrowKeyCode: 125) } ?? false) {
            let routedTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: routedTabs, window: shortcutRoutingKeyWindow)
            routedTabs?.movePaneFocus(direction: .down)
#if DEBUG
            recordGotoSplitMoveIfNeeded(direction: .down)
#endif
            return true
        }

        if matchConfiguredShortcut(event: event, action: .toggleSplitZoom) {
            let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
            performToggleSplitZoomShortcut(tabManager: routedManager)
#if DEBUG
            if routedManager?.selectedWorkspace?.layoutMode != .canvas {
                recordGotoSplitZoomIfNeeded(tabManager: routedManager)
            }
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
            // When the Dock owns keyboard focus, split the focused Dock pane
            // instead of the main area (checked before the transient-focus
            // suppression, which only guards main-terminal states).
            if routeSplitToFocusedDock(kind: .terminal, direction: .right, preferredWindow: event.window) {
                return true
            }
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
            if routeSplitToFocusedDock(kind: .terminal, direction: .down, preferredWindow: event.window) {
                return true
            }
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
            if routeSplitToFocusedDock(kind: .browser, direction: .right, preferredWindow: event.window) {
                return true
            }
            _ = performBrowserSplitShortcut(direction: .right)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .splitBrowserDown) {
#if DEBUG
            cmuxDebugLog("shortcut.action name=splitBrowserDown \(debugShortcutRouteSnapshot(event: event))")
#endif
            if routeSplitToFocusedDock(kind: .browser, direction: .down, preferredWindow: event.window) {
                return true
            }
            _ = performBrowserSplitShortcut(direction: .down)
            return true
        }

        // Surface navigation (legacy Ctrl+Tab support)
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)) {
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.selectNextSurface()
            return true
        }
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)) {
            (preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager)?.selectPreviousSurface()
            return true
        }

        // New surface: Cmd+T
        if matchConfiguredShortcut(event: event, action: .newSurface) {
            if routeCreateToFocusedDock(.terminal, focusAddressBar: false, preferredWindow: event.window) != nil {
                return true
            }
            tabManager?.newSurface()
            return true
        }

        // Open browser: Cmd+Shift+L
        if matchConfiguredShortcut(event: event, action: .openBrowser) {
            if routeCreateToFocusedDock(.browser, focusAddressBar: true, preferredWindow: event.window) != nil {
                return true
            }
            _ = openBrowserAndFocusAddressBar(insertAtEnd: true)
            return true
        }

        if matchConfiguredShortcut(event: event, action: .focusBrowserAddressBar) {
            if let focusedPanel = tabManager?.focusedBrowserPanel {
                focusBrowserAddressBar(in: focusedPanel)
                return true
            }

            if let browserAddressBarFocusedPanelId,
               focusBrowserAddressBar(panelId: browserAddressBarFocusedPanelId) {
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
            "zoom.shortcut stage=\(stage) event=\(NSWindow.keyDescription(event)) " +
            "chars='\(chars)' flags=\(browserZoomShortcutTraceFlagsString(flags)) " +
            "action=\(browserZoomShortcutTraceActionString(action)) keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType) panel=\(panelToken) zoom=\(String(format: "%.3f", panelZoom)) " +
            "addrBarId=\(browserAddressBarFocusedPanelId?.uuidString.prefix(8) ?? "nil")"
        if let handled {
            line += " handled=\(handled ? 1 : 0)"
        }
        cmuxDebugLog(line)
    }

    private func browserFocusStateSnapshot() -> String {
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let focused = tabManager?.selectedWorkspace?.focusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        let addressBar = browserAddressBarFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
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
        guard CmuxExtensionSidebarSelection.isEnabled else { return nil }
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
        browserAddressBarFocusedPanelId = panel.id
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
        browserAddressBarFocusedPanelId
    }

    func focusedBrowserOmnibarField(for event: NSEvent, in window: NSWindow?) -> OmnibarNativeTextField? {
        let panelId = focusedBrowserAddressBarPanelIdForShortcutEvent(event)
        return browserOmnibarField(panelId: panelId, in: window)
    }

    func clearBrowserAddressBarFocus(panelId: UUID, reason: String) {
        guard browserAddressBarFocusedPanelId == panelId else { return }
        browserAddressBarFocusedPanelId = nil
        stopBrowserOmnibarSelectionRepeat()
#if DEBUG
        cmuxDebugLog("addressBar CLEAR panelId=\(panelId.uuidString.prefix(8)) reason=\(reason)")
#endif
    }

    func focusedBrowserAddressBarPanelIdForShortcutEvent(_ event: NSEvent) -> UUID? {
        let shortcutWindow = resolvedShortcutEventWindow(event) ?? shortcutRoutingActiveWindow
        let shortcutResponder = shortcutWindow?.firstResponder
        let responderPanelId = isBrowserOmnibarResponder(shortcutResponder)
            ? browserOmnibarPanelId(for: shortcutResponder)
            : nil

        guard let context = preferredMainWindowContextForShortcutRouting(event: event) else {
#if DEBUG
            let candidatePanelId = responderPanelId ?? browserAddressBarFocusedPanelId
            guard let candidatePanelId else { return nil }
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(candidatePanelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_context event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        let intentPanelId = browserAddressBarIntentPanelId(in: context, window: shortcutWindow)
        guard let panelId = responderPanelId ?? browserAddressBarFocusedPanelId ?? intentPanelId else { return nil }

        guard let workspace = context.tabManager.selectedWorkspace else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=no_workspace event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        guard let panel = workspace.browserPanel(for: panelId) else {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=0 reason=panel_not_in_workspace workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return nil
        }

        if let responderPanelId {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(responderPanelId.uuidString.prefix(5)) " +
                "accepted=1 reason=omnibar_responder workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return responderPanelId
        }

        if intentPanelId == panelId, browserAddressBarFocusedPanelId == nil {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=1 reason=addressbar_intent workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
            )
#endif
            return panelId
        }

        let liveOmnibarFieldExists = browserOmnibarField(panelId: panelId, in: shortcutWindow) != nil
        let trackedPanelMatchesShortcutResponder = browserPanel(panel, ownsShortcutResponder: shortcutResponder, in: shortcutWindow)
        let trackingContext = BrowserAddressBarTrackingContext(
            trackedPanelMatchesWebView: trackedPanelMatchesShortcutResponder,
            omnibarResponderActive: false,
            preferredFocusIntentIsAddressBar: panel.preferredFocusIntent == .addressBar,
            suppressesWebViewFocus: panel.shouldSuppressWebViewFocus(),
            pointerInitiatedWebFocus: false,
            liveOmnibarFieldExists: liveOmnibarFieldExists
        )
        if shouldPreserveBrowserAddressBarTrackingDuringWebViewFocus(trackingContext) {
#if DEBUG
            cmuxDebugLog(
                "browser.focus.addressBar.shortcutContext panel=\(panelId.uuidString.prefix(5)) " +
                "accepted=1 reason=tracked_omnibar_field workspace=\(workspace.id.uuidString.prefix(5)) " +
                "event=\(NSWindow.keyDescription(event))"
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
                "event=\(NSWindow.keyDescription(event))"
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
            "event=\(NSWindow.keyDescription(event))"
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
        guard browserAddressBarFocusedPanelId == panel.id else { return false }
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
        if browserOmnibarPanelId(for: responder) == panel.id {
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
        in context: MainWindowContext,
        window: NSWindow?
    ) -> UUID? {
        guard let workspace = context.tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let panel = workspace.browserPanel(for: focusedPanelId),
              panel.preferredFocusIntent == .addressBar,
              let field = browserOmnibarField(panelId: panel.id, in: window) else {
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
        if browserOmnibarPanelId(for: responder) == panel.id {
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
        guard browserAddressBarFocusedPanelId == panel.id else { return false }
        let resolvedWindow = window ?? panel.webView.window
        let trackingContext = BrowserAddressBarTrackingContext(
            trackedPanelMatchesWebView: trackedPanelMatchesWebView,
            omnibarResponderActive: isBrowserOmnibarResponder(resolvedWindow?.firstResponder),
            preferredFocusIntentIsAddressBar: panel.preferredFocusIntent == .addressBar,
            suppressesWebViewFocus: panel.shouldSuppressWebViewFocus(),
            pointerInitiatedWebFocus: pointerInitiatedWebFocus,
            liveOmnibarFieldExists: browserOmnibarField(panelId: panel.id, in: resolvedWindow) != nil
        )
        return shouldPreserveBrowserAddressBarTrackingDuringWebViewFocus(trackingContext)
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
        browserOmnibarSelectionDeltaForControlNavigation(
            hasFocusedAddressBar: hasFocusedAddressBar,
            flags: flags,
            chars: chars
        )
    }

    private func dispatchBrowserOmnibarSelectionMove(panelId: UUID, delta: Int) {
        browserOmnibarSelectionRepeat.dispatchSelectionMove(panelID: panelId, delta: delta)
    }

    private func startBrowserOmnibarSelectionRepeatIfNeeded(panelId: UUID, keyCode: UInt16, delta: Int) {
        browserOmnibarSelectionRepeat.startRepeatIfNeeded(panelID: panelId, keyCode: keyCode, delta: delta)
    }

    private func stopBrowserOmnibarSelectionRepeat() {
        browserOmnibarSelectionRepeat.stopRepeat()
    }

    private func handleBrowserOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        switch event.type {
        case .keyUp:
            browserOmnibarSelectionRepeat.noteKeyUp(keyCode: event.keyCode)
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            browserOmnibarSelectionRepeat.noteFlagsChanged(
                shouldContinue: browserOmnibarShouldContinueControlNavigationRepeat(flags: flags),
                flagsRawValue: flags.rawValue
            )
        default:
            break
        }
    }

    private func isLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
        cmuxIsLikelyWebInspectorResponder(responder)
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
        let eventDescription = event.map(NSWindow.keyDescription) ?? "none"
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

    private func prepareFocusedBrowserDevToolsForSplit(directionLabel: String) {
        guard let browser = tabManager?.focusedBrowserPanel else { return }
        guard browser.shouldPreserveWebViewAttachmentDuringTransientHide() else { return }
        guard let keyWindow = shortcutRoutingKeyWindow else { return }
        guard isLikelyWebInspectorResponder(keyWindow.firstResponder) else { return }

        let beforeResponder = keyWindow.firstResponder
        let movedToWebView = keyWindow.makeFirstResponder(browser.webView)
        let movedToNil = movedToWebView ? false : keyWindow.makeFirstResponder(nil)

        #if DEBUG
        let beforeType = beforeResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let beforePtr = beforeResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let afterResponder = keyWindow.firstResponder
        let afterType = afterResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let afterPtr = afterResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        cmuxDebugLog(
            "split.shortcut inspector.preflight dir=\(directionLabel) panel=\(browser.id.uuidString.prefix(5)) " +
            "before=\(beforeType)@\(beforePtr) after=\(afterType)@\(afterPtr) " +
            "moveWeb=\(movedToWebView ? 1 : 0) moveNil=\(movedToNil ? 1 : 0) \(browser.debugDeveloperToolsStateSummary())"
        )
        #endif
    }

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

        prepareFocusedBrowserDevToolsForSplit(directionLabel: directionLabel)
        let didCreateSplit: Bool = {
            if let terminalContext {
                if let workspace = terminalContext.tabManager.tabs.first(where: { $0.id == terminalContext.workspaceId }),
                   workspace.layoutMode == .canvas {
                    return workspace.openNewCanvasPane(
                        type: .terminal,
                        focus: true,
                        direction: direction.canvasDirection
                    ) != nil
                }
                return terminalContext.tabManager.createSplit(
                    tabId: terminalContext.workspaceId,
                    surfaceId: terminalContext.panelId,
                    direction: direction
                ) != nil
            }
            if let workspace = tabManager?.selectedWorkspace,
               workspace.layoutMode == .canvas {
                return workspace.openNewCanvasPane(
                    type: .terminal,
                    focus: true,
                    direction: direction.canvasDirection
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
        commandPaletteWindowStore.setPendingOpenAge(
            windowId,
            now: ProcessInfo.processInfo.systemUptime,
            age: age
        )
        return true
    }

    // Test hook: remap a window context under a detached window key so direct
    // ObjectIdentifier(window) lookups fail and fallback logic is exercised.
    @discardableResult
    func debugInjectWindowContextKeyMismatch(windowId: UUID) -> Bool {
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
              let window = context.window ?? windowForMainWindowId(windowId) else {
            return false
        }

        let detachedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        debugDetachedContextWindows.append(detachedWindow)

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        mainWindowContexts[ObjectIdentifier(detachedWindow)] = context
        context.window = window
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
        if let pendingConfiguredShortcutChord,
           pendingConfiguredShortcutChord.windowNumber == configuredShortcutEventWindowNumber {
            activeConfiguredShortcutChordPrefixForCurrentEvent = pendingConfiguredShortcutChord.firstStroke
        } else {
            activeConfiguredShortcutChordPrefixForCurrentEvent = nil
        }
        pendingConfiguredShortcutChord = nil
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
        guard !shortcut.isUnbound else { return false }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchShortcutStroke(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return false }
        return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }

    func matchConfiguredShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        if !shortcutWhenClauseAllows(action: action, event: event) { return false }
        return matchConfiguredShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: action))
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
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return nil }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return nil
            }
            return numberedShortcutDigit(event: event, stroke: secondStroke)
        }
        guard !shortcut.isUnbound, !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    private func routableNumberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        if let digit = numberedConfiguredShortcutDigit(event: event, action: action), shortcutWhenClauseAllows(action: action, event: event) { return digit }
        return nil
    }

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
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        guard !shortcut.isUnbound else { return false }
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchDirectionalShortcut(
                event: event,
                stroke: secondStroke,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode
            )
        }
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
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

    private func armConfiguredShortcutChordIfNeeded(
        event: NSEvent,
        actions: [KeyboardShortcutSettings.Action],
        shortcuts: [StoredShortcut] = []
    ) -> Bool {
        var seen = Set<StoredShortcut>()
        let configuredShortcuts = actions.map {
            KeyboardShortcutSettings.shortcut(for: $0)
        } + shortcuts
        for shortcut in configuredShortcuts {
            guard seen.insert(shortcut).inserted else { continue }
            guard shortcut.hasChord else { continue }
            if matchShortcutStroke(event: event, stroke: shortcut.firstStroke) {
                pendingConfiguredShortcutChord = PendingConfiguredShortcutChord(
                    firstStroke: shortcut.firstStroke,
                    windowNumber: configuredShortcutChordWindowNumber(for: event)
                )
                return true
            }
        }
        return false
    }

    func configuredCmuxShortcutActions(
        for context: MainWindowContext?
    ) -> [CmuxResolvedConfigAction] {
        context?.cmuxConfigStore?.shortcutActions() ?? []
    }

    private func handleConfiguredCmuxShortcut(
        event: NSEvent,
        actions: [CmuxResolvedConfigAction],
        context: MainWindowContext?
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
        context: MainWindowContext?
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
        guard let context = mainWindowContexts.values.first(where: { $0.tabManager === tabManager }) else {
            return false
        }
        let anchorId = tabManager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId
        let groupPlacement: WorkspaceGroupNewPlacement = {
            let cwd = anchorId.flatMap { id in
                tabManager.tabs.first(where: { $0.id == id })?.currentDirectory
            }
            let configured = context.cmuxConfigStore?.resolveWorkspaceGroupConfig(forCwd: cwd)?.newWorkspacePlacement
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
        let onExecuted: () -> Void = { [weak tabManager, groupId, beforeIds, previousSelectedId, anchorId, groupPlacement, action] in
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
            // cloudVM launches a `cmux vm base open` process and returns before the
            // workspace appears in tabs[]. The synchronous diff above misses
            // it, so watch the tab list while the process is running. Process
            // completion also reports the created workspace UUID as an exact
            // fallback.
            if newlyCreatedId == nil, case .builtIn(.cloudVM) = action.action {
                asyncObserverId = ConfiguredGroupActionAsyncWorkspaceObserver.install(
                    tabManager: tabManager,
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
        let onCloudVMCompletion: (CloudVMActionLauncher.Completion) -> Void = { [weak tabManager] completion in
            guard let tabManager, let asyncObserverId else { return }
            ConfiguredGroupActionAsyncWorkspaceObserver.finishPending(
                tabManager: tabManager,
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
        context: MainWindowContext,
        preferredWindow: NSWindow? = nil,
        onExecuted: (() -> Void)? = nil,
        onCloudVMCompletion: ((CloudVMActionLauncher.Completion) -> Void)? = nil
    ) -> Bool {
        switch action.action {
        case .builtIn(let builtIn):
            switch builtIn {
            case .newWorkspace:
                context.tabManager.addWorkspace()
                onExecuted?()
                return true
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
            }
        case .command, .agent, .workspaceCommand, .workspace:
            guard let cmuxConfigStore = context.cmuxConfigStore else {
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
    private func matchShortcutStroke(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        stroke.matches(event: event, layoutCharacterProvider: shortcutLayoutCharacterProvider)
    }

    private func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        shortcut.matches(event: event, layoutCharacterProvider: shortcutLayoutCharacterProvider)
    }

    private func matchesKeyboardShortcutEvent(
        _ event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        shortcut: StoredShortcut
    ) -> Bool {
        guard !shortcut.isUnbound else { return false }
        if action.usesNumberedDigitMatching {
            return numberedShortcutDigit(event: event, shortcut: shortcut) != nil
        }
        guard !shortcut.hasChord else { return false }
        return matchShortcut(event: event, shortcut: shortcut)
    }

    func shouldSuppressStaleCmuxMenuShortcut(event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // While a Settings recorder is armed, every keystroke must reach it to be
        // captured — including a remapped-away default like the old ⌘1 the user is
        // trying to record. Suppressing the stale menu shortcut here would consume
        // that keystroke before `RecorderHostButton.performKeyEquivalent` sees it,
        // so stand down for both recorders (issue #5189).
        if KeyboardShortcutRecorderActivity.isAnyRecorderActive || RecorderHostButton.isActivelyRecording {
            return false
        }
        let keyWindow = shortcutRoutingKeyWindow
        if event.window is NSPanel || keyWindow is NSPanel || NSApp.modalWindow != nil || keyWindow?.attachedSheet != nil {
            return false
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags.contains(.command) else { return false }

        let staleDefaultActions = KeyboardShortcutSettings.Action.allCases.filter { action in
            isMenuBackedShortcutAction(action) &&
                matchesKeyboardShortcutEvent(event, action: action, shortcut: action.defaultShortcut)
        }
        guard !staleDefaultActions.isEmpty else { return false }

        for action in staleDefaultActions {
            if currentShortcutMatchesKeyboardShortcutEvent(event, action: action) {
                return false
            }
        }

        if staleDefaultActions.contains(where: isCloseShortcutAction) {
            return true
        }

        for action in KeyboardShortcutSettings.Action.allCases where canCurrentShortcutPreventStaleMenuSuppression(action) {
            if currentShortcutMatchesKeyboardShortcutEvent(event, action: action) {
                return false
            }
        }
        return true
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

    private func isMenuBackedShortcutAction(_ action: KeyboardShortcutSettings.Action) -> Bool {
        action != .showHideAllWindows
            && action != .globalSearch
            && action != .clearScreenKeepScrollback
            && action != .fileExplorerOpenSelection
            && action != .fileExplorerOpenSelectionFinderAlias
    }

    private func canCurrentShortcutPreventStaleMenuSuppression(_ action: KeyboardShortcutSettings.Action) -> Bool {
        action != .fileExplorerOpenSelection && action != .fileExplorerOpenSelectionFinderAlias
    }

    private func isCloseShortcutAction(_ action: KeyboardShortcutSettings.Action) -> Bool {
        switch action {
        case .closeTab, .closeWorkspace, .closeWindow:
            return true
        default:
            return false
        }
    }

    private func numberedShortcutDigit(event: NSEvent, stroke: ShortcutStroke) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == stroke.modifierFlags else { return nil }
        let numberKeyDigit = digitForNumberKeyCode(event.keyCode)

        if let digit = numberedShortcutDigit(
            eventCharacter: event.charactersIgnoringModifiers,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: event.keyCode
        ) {
            return digit
        }

        let eventCharsIgnoringModifiers = event.charactersIgnoringModifiers
        let hasUsableASCIIEventChars = !(eventCharsIgnoringModifiers?.isEmpty ?? true)
            && (eventCharsIgnoringModifiers?.allSatisfy(\.isASCII) ?? true)
        if !hasUsableASCIIEventChars || numberKeyDigit != nil {
            let layoutCharacter = shortcutLayoutCharacterProvider(event.keyCode, event.modifierFlags)
            if let digit = numberedShortcutDigit(
                eventCharacter: layoutCharacter,
                applyShiftSymbolNormalization: false,
                eventKeyCode: event.keyCode
            ) {
                return digit
            }
        }

        return numberKeyDigit
    }

    private func numberedShortcutDigit(event: NSEvent, shortcut: StoredShortcut) -> Int? {
        guard !shortcut.isUnbound, !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    private func numberedShortcutDigit(
        eventCharacter: String?,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Int? {
        guard let eventCharacter, !eventCharacter.isEmpty else { return nil }
        let normalized = normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        )
        guard let digit = Int(normalized), (1...9).contains(digit) else { return nil }
        return digit
    }

    private func eventCouldMatchNumberedShortcutDigit(_ event: NSEvent) -> Bool {
        if digitForNumberKeyCode(event.keyCode) != nil {
            return true
        }
        return numberedShortcutDigit(
            eventCharacter: event.charactersIgnoringModifiers,
            applyShiftSymbolNormalization: false,
            eventKeyCode: event.keyCode
        ) != nil
    }

    private func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()
        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
        case "{": return "["
        case "}": return "]"
        case "<": return eventKeyCode == 43 ? "," : lowered // kVK_ANSI_Comma
        case ">": return eventKeyCode == 47 ? "." : lowered // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "+": return "="
        case "_": return "-"
        case "!": return eventKeyCode == 18 ? "1" : lowered // kVK_ANSI_1
        case "@": return eventKeyCode == 19 ? "2" : lowered // kVK_ANSI_2
        case "#": return eventKeyCode == 20 ? "3" : lowered // kVK_ANSI_3
        case "$": return eventKeyCode == 21 ? "4" : lowered // kVK_ANSI_4
        case "%": return eventKeyCode == 23 ? "5" : lowered // kVK_ANSI_5
        case "^": return eventKeyCode == 22 ? "6" : lowered // kVK_ANSI_6
        case "&": return eventKeyCode == 26 ? "7" : lowered // kVK_ANSI_7
        case "*": return eventKeyCode == 28 ? "8" : lowered // kVK_ANSI_8
        case "(": return eventKeyCode == 25 ? "9" : lowered // kVK_ANSI_9
        case ")": return eventKeyCode == 29 ? "0" : lowered // kVK_ANSI_0
        default: return lowered
        }
    }

    private func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1 // kVK_ANSI_1
        case 19: return 2 // kVK_ANSI_2
        case 20: return 3 // kVK_ANSI_3
        case 21: return 4 // kVK_ANSI_4
        case 23: return 5 // kVK_ANSI_5
        case 22: return 6 // kVK_ANSI_6
        case 26: return 7 // kVK_ANSI_7
        case 28: return 8 // kVK_ANSI_8
        case 25: return 9 // kVK_ANSI_9
        default:
            return nil
        }
    }

    /// Match arrow key shortcuts using keyCode
    /// Arrow keys include .numericPad and .function in their modifierFlags, so strip those before comparing.
    private func matchArrowShortcut(event: NSEvent, stroke: ShortcutStroke, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && flags == stroke.modifierFlags
    }

    /// Match tab key shortcuts using keyCode 48
    private func matchTabShortcut(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == stroke.modifierFlags
    }

    private func matchTabShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchTabShortcut(event: event, stroke: shortcut.firstStroke)
    }

    /// Directional shortcuts default to arrow keys, but the shortcut recorder only supports letter/number keys.
    /// Support both so users can customize pane navigation (e.g. Cmd+Ctrl+H/J/K/L).
    private func matchDirectionalShortcut(
        event: NSEvent,
        stroke: ShortcutStroke,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        if stroke.key == arrowGlyph {
            return matchArrowShortcut(event: event, stroke: stroke, keyCode: arrowKeyCode)
        }
        return matchShortcutStroke(event: event, stroke: stroke)
    }

    private func matchDirectionalShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // User-initiated update checks are always allowed; other items are unconditionally valid
        // (this preserves the prior UpdateController.validateMenuItem behavior).
        true
    }

    private func configureUserNotifications() {
        notificationDelivery.configureUserNotifications(delegate: self)
    }

    private func disableNativeTabbingShortcut() {
        guard let menu = NSApp.mainMenu else { return }
        disableMenuItemShortcut(in: menu, action: #selector(NSWindow.toggleTabBar(_:)))
    }

    private func disableMenuItemShortcut(in menu: NSMenu, action: Selector) {
        for item in menu.items {
            if item.action == action {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemShortcut(in: submenu, action: action)
            }
        }
    }

    private func ensureApplicationIcon() {
        let mode = AppIconSettings.resolvedMode()
        AppIconSettings.applyIcon(mode)
    }

    private func scheduleLaunchServicesBundleRegistration(
        bundleURL: URL = Bundle.main.bundleURL.standardizedFileURL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void = AppDelegate.enqueueLaunchServicesRegistrationWork,
        register: @escaping (CFURL) -> OSStatus = { url in
            LSRegisterURL(url, true)
        },
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { message, data in
            sentryBreadcrumb(message, category: "startup", data: data)
        }
    ) {
        let normalizedURL = bundleURL.standardizedFileURL
        breadcrumb("launchservices.register.schedule", [
            "bundlePath": normalizedURL.path
        ])

        scheduler {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let registerStatus = register(normalizedURL as CFURL)
            let durationMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())

            breadcrumb("launchservices.register.complete", [
                "bundlePath": normalizedURL.path,
                "status": Int(registerStatus),
                "durationMs": durationMs
            ])

            if registerStatus != noErr {
                NSLog("LaunchServices registration failed (status: \(registerStatus)) for \(normalizedURL.path)")
            }
        }
    }

#if DEBUG
    func scheduleLaunchServicesBundleRegistrationForTesting(
        bundleURL: URL,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void,
        register: @escaping (CFURL) -> OSStatus,
        breadcrumb: @escaping (_ message: String, _ data: [String: Any]) -> Void = { _, _ in }
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
        guard let bundleId = Bundle.main.bundleIdentifier else {
            StartupBreadcrumbLog.append("singleInstance.enforce.skip", fields: ["reason": "missingBundleId"])
            return
        }
        let currentPid = ProcessInfo.processInfo.processIdentifier
        var terminatedPids: [String] = []

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            guard app.processIdentifier != currentPid else { continue }
            terminatedPids.append(String(app.processIdentifier))
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
        }
        StartupBreadcrumbLog.append(
            "singleInstance.enforce.complete",
            fields: [
                "bundleIdentifier": bundleId,
                "currentPid": String(currentPid),
                "terminatedPids": terminatedPids.joined(separator: ",")
            ]
        )
    }

    private func observeDuplicateLaunches() {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            StartupBreadcrumbLog.append("singleInstance.observe.skip", fields: ["reason": "missingBundleId"])
            return
        }
        let embeddedCLIURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/cmux", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let currentPid = ProcessInfo.processInfo.processIdentifier
        StartupBreadcrumbLog.append(
            "singleInstance.observe.install",
            fields: [
                "bundleIdentifier": bundleId,
                "currentPid": String(currentPid)
            ]
        )

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self != nil else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier == bundleId, app.processIdentifier != currentPid else { return }
            if let executableURL = app.executableURL?
                   .standardizedFileURL
                   .resolvingSymlinksInPath(),
               executableURL == embeddedCLIURL {
                return
            }

            StartupBreadcrumbLog.append(
                "singleInstance.observe.terminateDuplicate",
                fields: [
                    "duplicatePid": String(app.processIdentifier),
                    "duplicateBundleIdentifier": app.bundleIdentifier ?? "nil"
                ]
            )
            app.terminate()
            if !app.isTerminated {
                _ = app.forceTerminate()
            }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
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
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.browserPanel(for: panelId)?.beginSuppressWebViewFocusForAddressBar()
            self.browserAddressBarFocusedPanelId = panelId
            self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
            cmuxDebugLog("addressBar FOCUS panelId=\(panelId.uuidString.prefix(8))")
#endif
        }

        browserAddressBarBlurObserver = NotificationCenter.default.addObserver(
            forName: .browserDidBlurAddressBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let panelId = notification.object as? UUID else { return }
            self.browserPanel(for: panelId)?.endSuppressWebViewFocusForAddressBar()
            if self.browserAddressBarFocusedPanelId == panelId {
                self.browserAddressBarFocusedPanelId = nil
                self.stopBrowserOmnibarSelectionRepeat()
#if DEBUG
                cmuxDebugLog("addressBar BLUR panelId=\(panelId.uuidString.prefix(8))")
#endif
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
        let pointerInitiatedKey = BrowserFirstResponderNotificationUserInfoKey.pointerInitiated
        let pointerInitiated = notification.userInfo?[pointerInitiatedKey] as? Bool ?? false

        if let trackedPanelId = browserAddressBarFocusedPanelId,
           trackedPanelId != panel.id,
           let trackedPanel = browserPanel(for: trackedPanelId),
           !shouldPreserveBrowserAddressBarTracking(
               for: trackedPanel,
               trackedPanelMatchesWebView: false,
               pointerInitiatedWebFocus: pointerInitiated,
               in: trackedPanel.webView.window
           ) {
            trackedPanel.endSuppressWebViewFocusForAddressBar()
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
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
        if browserAddressBarFocusedPanelId == panel.id {
            browserAddressBarFocusedPanelId = nil
            stopBrowserOmnibarSelectionRepeat()
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

    private func isWebViewFocused(_ panel: BrowserPanel) -> Bool {
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
        for context in mainWindowContexts.values {
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

    private func activateMainWindowContext(_ context: MainWindowContext?) {
        guard let context else {
            tabManager = nil
            sidebarState = nil
            sidebarSelectionState = nil
            fileExplorerState = nil
            TerminalController.shared.setActiveTabManager(nil)
            return
        }
        tabManager = context.tabManager
        sidebarState = context.sidebarState
        sidebarSelectionState = context.sidebarSelectionState
        fileExplorerState = context.fileExplorerState
        TerminalController.shared.setActiveTabManager(context.tabManager)
    }

    func setActiveMainWindow(_ window: NSWindow) {
        guard let context = contextForMainTerminalWindow(window) else { return }
#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
#endif
        activateMainWindowContext(context)
#if DEBUG
        cmuxDebugLog(
            "mainWindow.active window={\(debugWindowToken(window))} context={\(debugContextToken(context))} beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) \(debugShortcutRouteSnapshot())"
        )
#endif
    }

    private func handleMainTerminalWindowShouldClose() -> Bool {
        // XCTest has no UI for the warn-before-quit dialog and would either block
        // on runModal or have NSApp.terminate kill the test process.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        guard !isTerminatingApp, mainWindowContexts.count <= 1 else { return true }
        _ = handleQuitShortcutWarning()
        return false
    }

    private func unregisterMainWindow(_ window: NSWindow) {
        // Reset cascade point so the next new window appears near the closing
        // window's position, matching upstream Ghostty behavior.
        let frame = window.frame
        lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        let closingContext = contextForMainTerminalWindow(window, reindex: false)
        let closingWindowIsCrashDiagnostic = closingContext.map { context in
            closeWindowSnapshotPruningCrashDiagnostics(
                for: context,
                includeScrollback: false,
                restorableAgentIndex: SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh() ?? .empty
            )
                .isCrashDiagnostic
        } ?? false

        if let closingContext, !closingWindowIsCrashDiagnostic {
            recordClosedWindowHistoryIfNeeded(for: closingContext)
        }

        // Keep geometry available as a fallback for the next window placement,
        // and remember the closing frame for the current configuration.
        if !isTerminatingApp {
            captureWindowConfigFrame(window, reason: "windowClose")
            persistWindowGeometry(from: window)
        }
        mainWindowVisibilityController.discardClosedWindow(window)

        guard let removed = unregisterMainWindowContext(for: window) else { return }
        windowConfigFrames.removeValue(forKey: removed.windowId)
        publishCmuxWindowLifecycle(name: "window.closed", windowId: removed.windowId, origin: "appkit_close")
        commandPaletteWindowStore.removeWindow(removed.windowId)

        // Avoid stale notifications that can no longer be opened once the owning window is gone.
        if let store = notificationStore {
            store.clearNotifications(forTabId: removed.windowId)
            for tab in removed.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }

        if tabManager === removed.tabManager {
            // Repoint "active" pointers to any remaining main terminal window.
            let nextContext: MainWindowContext? = {
                if let keyWindow = shortcutRoutingKeyWindow,
                   let ctx = contextForMainTerminalWindow(keyWindow, reindex: false) {
                    return ctx
                }
                return mainWindowContexts.values.first
            }()

            activateMainWindowContext(nextContext)
        }

        // During app termination we already persisted a full snapshot (with scrollback)
        // in applicationShouldTerminate/applicationWillTerminate. Saving again here would
        // overwrite it as windows tear down one-by-one, dropping closed windows and replay.
        if Self.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: isTerminatingApp) {
            saveSessionSnapshotAfterLoadingProcessDetectedIndexes(
                includeScrollback: false,
                removeWhenEmpty: closingWindowIsCrashDiagnostic,
                preserveManualRestoreBackupOnMissingPrimary: closingWindowIsCrashDiagnostic
            )
        }
    }

    private func closeWindowSnapshotPruningCrashDiagnostics(
        for context: MainWindowContext,
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
                version: SessionSnapshotSchema.currentVersion,
                createdAt: Date().timeIntervalSince1970,
                windows: [windowSnapshot]
            )
        )
        return (
            pruned.snapshot?.windows.first,
            pruned.removedAny && pruned.snapshot == nil
        )
    }

    private func recordClosedWindowHistoryIfNeeded(for context: MainWindowContext) {
        let shouldSuppressClosedWindowHistory = closedWindowHistorySuppressedWindowIds.remove(context.windowId) != nil
        guard !shouldSuppressClosedWindowHistory,
              !isTerminatingApp,
              !isApplyingSessionRestore else {
            return
        }
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
        ClosedItemHistoryStore.shared.push(.window(ClosedWindowHistoryEntry(
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
        guard let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) else { return }
        recordClosedWindowHistoryIfNeeded(for: context)
    }

    func isClosedWindowHistorySuppressedForTesting(windowId: UUID) -> Bool {
        closedWindowHistorySuppressedWindowIds.contains(windowId)
    }
#endif

    func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        if mainWindowContexts[ObjectIdentifier(window)] != nil {
            return true
        }
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
    }

    private func workspaceForMainActor(tabId: UUID) -> Workspace? {
        tabManagerFor(tabId: tabId)?.tabs.first(where: { $0.id == tabId })
    }

    /// Returns the `Workspace` that owns `tabId`, if any.
    @MainActor
    func workspaceFor(tabId: UUID) -> Workspace? {
        workspaceForMainActor(tabId: tabId)
    }

    func closeMainWindowContainingTabId(_ tabId: UUID, recordHistory: Bool = true) {
#if DEBUG
        closeMainWindowContainingTabIdObserverForTesting?(tabId, recordHistory)
#endif
        guard let context = contextContainingTabId(tabId) else { return }
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
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
        notificationNavigation.openNotification(
            NotificationNavSnapshot(
                id: notification.id,
                tabId: notification.tabId,
                surfaceId: notification.surfaceId,
                panelId: notification.panelId,
                isRead: notification.isRead,
                clickAction: notification.clickAction.map(Self.navClickAction),
                scrollRow: notification.scrollPosition?.row,
                scrollTotalRows: notification.scrollPosition?.totalRows
            )
        )
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
        notificationClickPerformer.perform(Self.navClickAction(action))
    }

#if DEBUG
    func recordJumpUnreadFocusFromModelIfNeeded(
        tabManager: TabManager,
        tabId: UUID,
        expectedSurfaceId: UUID?
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let expectedSurfaceId else { return }

        // Ensure the expectation is armed even if the view doesn't become first responder.
        armJumpUnreadFocusRecord(tabId: tabId, surfaceId: expectedSurfaceId)

        if tabManager.selectedTabId == tabId,
           tabManager.focusedSurfaceId(for: tabId) == expectedSurfaceId {
            recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: expectedSurfaceId)
        }
    }
#endif

    func tabTitle(for tabId: UUID) -> String? {
        if let context = contextContainingTabId(tabId) {
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
    func recordMultiWindowNotificationOpenFailureIfNeeded(
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?,
        reason: String
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CMUX_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        let contextSummaries: [String] = mainWindowContexts.values.map { ctx in
            let tabIds = ctx.tabManager.tabs.map { $0.id.uuidString }.joined(separator: ",")
            let hasWindow = (ctx.window != nil) ? "1" : "0"
            return "windowId=\(ctx.windowId.uuidString) hasWindow=\(hasWindow) tabs=[\(tabIds)]"
        }

        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "openFailureTabId": tabId.uuidString,
            "openFailureSurfaceId": surfaceId?.uuidString ?? "",
            "openFailureNotificationId": notificationId?.uuidString ?? "",
            "openFailureReason": reason,
            "openFailureContexts": contextSummaries.joined(separator: "; "),
        ], at: path)
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
private var cmuxFieldEditorOwningWebViewAssociationKey: UInt8 = 0

private final class CmuxFieldEditorOwningWebViewBox: NSObject {
    weak var webView: CmuxWebView?

    init(webView: CmuxWebView?) {
        self.webView = webView
    }
}

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
            if AppDelegate.shared?.handleFocusedFileExplorerOpenSelectionShortcut(
                event,
                preferredWindow: event.window ?? keyWindow ?? mainWindow
            ) == true {
#if DEBUG
                cmuxDebugLog("app.sendEvent routed file explorer shortcut before stale cmux menu shortcut")
#endif
                return
            }
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
    func handleDetachedInspectorWindowCloseAction(
        action: Selector,
        target: Any?,
        sender: Any?
    ) -> Bool {
        guard Thread.isMainThread else { return false }

        return MainActor.assumeIsolated {
            guard Self.shouldInterceptWindowCloseAction(
                action,
                target: target,
                sender: sender
            ) else { return false }
            guard let window = Self.actionWindow(
                target: target,
                sender: sender,
                allowFallback: Self.allowsWindowFallback(for: action)
            ),
                  BrowserPanel.isDetachedInspectorWindow(window) else { return false }

            for panel in allBrowserPanelsForInspectorWindowClose() {
                if panel.closeDeveloperToolsFromDetachedInspectorWindowUserAction(
                    window,
                    source: "sendAction.\(NSStringFromSelector(action))"
                ) {
#if DEBUG
                    cmuxDebugLog(
                        "browser.devtools detachedClose.action panel=\(panel.id.uuidString.prefix(5)) " +
                        "action=\(NSStringFromSelector(action)) window=\(window.windowNumber)"
                    )
#endif
                    return true
                }
            }

            return false
        }
    }

    private static func shouldInterceptWindowCloseAction(
        _ action: Selector,
        target: Any?,
        sender: Any?
    ) -> Bool {
        switch NSStringFromSelector(action) {
        case "__close", "performClose:":
            return true
        case "close", "close:":
            return actionWindow(target: target, sender: sender, allowFallback: false) != nil
        default:
            return false
        }
    }

    private static func allowsWindowFallback(for action: Selector) -> Bool {
        switch NSStringFromSelector(action) {
        case "__close", "performClose:":
            return true
        default:
            return false
        }
    }

    private static func actionWindow(
        target: Any?,
        sender: Any?,
        allowFallback: Bool = true
    ) -> NSWindow? {
        if let window = target as? NSWindow {
            return window
        }
        if let window = sender as? NSWindow {
            return window
        }
        if let view = sender as? NSView {
            return view.window
        }
        if let cell = sender as? NSCell {
            return cell.controlView?.window
        }
        if target == nil, sender is NSMenuItem {
            return AppDelegate.shared?.shortcutRoutingActiveWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return allowFallback ? (AppDelegate.shared?.shortcutRoutingActiveWindow ?? NSApp.keyWindow ?? NSApp.mainWindow) : nil
    }

    private func allBrowserPanelsForInspectorWindowClose() -> [BrowserPanel] {
        var candidateManagers: [TabManager] = []
        var seenManagers = Set<ObjectIdentifier>()
        var panels: [BrowserPanel] = []
        var seenPanels = Set<ObjectIdentifier>()

        func appendCandidate(_ manager: TabManager?) {
            guard let manager else { return }
            let identifier = ObjectIdentifier(manager)
            guard seenManagers.insert(identifier).inserted else { return }
            candidateManagers.append(manager)
        }

        appendCandidate(tabManager)
        for context in mainWindowContexts.values {
            appendCandidate(context.tabManager)
        }
        for route in recoverableMainWindowRoutes() {
            appendCandidate(route.tabManager)
        }

        for manager in candidateManagers {
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    guard let browserPanel = panel as? BrowserPanel else { continue }
                    let identifier = ObjectIdentifier(browserPanel)
                    guard seenPanels.insert(identifier).inserted else { continue }
                    panels.append(browserPanel)
                }
            }
        }

        return panels
    }

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

private extension NSWindow {
    static func cmuxCommandPaletteOwnsFieldEditor(_ textView: NSTextView?, in window: NSWindow) -> Bool {
        guard let textView,
              textView.isFieldEditor,
              textView.window === window else {
            return false
        }

        if let ownerView = cmuxFieldEditorOwnerView(textView) {
            guard let container = cmuxCommandPaletteOverlayAncestor(of: ownerView) else {
                return false
            }
            return cmuxCommandPaletteOverlayIsPresented(container)
        }

        guard let container = cmuxCommandPaletteOverlayContainer(in: window) else {
            return false
        }

        return cmuxCommandPaletteOverlayIsPresented(container)
    }

    private static func cmuxCommandPaletteOverlayAncestor(of view: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            current = candidate.superview
        }
        return nil
    }

    private static func cmuxCommandPaletteOverlayIsPresented(_ container: NSView) -> Bool {
        !container.isHidden && container.alphaValue > 0.001
    }

    private static func cmuxCommandPaletteOverlayContainer(in window: NSWindow) -> NSView? {
        guard let searchRoot = window.contentView?.superview ?? window.contentView else {
            return nil
        }
        var stack: [NSView] = [searchRoot]
        while let candidate = stack.popLast() {
            if candidate.identifier == commandPaletteOverlayContainerIdentifier {
                return candidate
            }
            stack.append(contentsOf: candidate.subviews)
        }
        return nil
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
        // recordTypingActivity must run in all builds so runSessionAutosaveTick
        // can honor the typing quiet period in release.
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
        let hasActiveSuppressionSequence = activeWindowMoveSuppressionSequenceReason(window: self) != nil
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
                finishedReason = finishWindowMoveSuppressionSequence(window: self)
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
        let depth = windowDragSuppressionDepth(window: self)
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
        cmuxDebugLog("performKeyEquiv: \(Self.keyDescription(event)) fr=\(frType)")
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
        let firstResponderOmnibarPanelId = browserOmnibarPanelId(for: self.firstResponder)
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
            if AppDelegate.shared?.handleFocusedFileExplorerOpenSelectionShortcut(event, preferredWindow: self) == true {
#if DEBUG
                cmuxDebugLog("  → consumed by file explorer shortcut before stale cmux menu shortcut")
#endif
                return true
            }
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

                if shouldDispatchTerminalArrowViaFirstResponderKeyDown(
                    keyCode: event.keyCode,
                    firstResponderIsTerminal: true,
                    firstResponderHasMarkedText: ghosttyView.hasMarkedText(),
                    flags: event.modifierFlags
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
                    cmuxDebugLog("zoom.shortcut stage=window.ghosttyKeyDownDirect event=\(Self.keyDescription(event)) handled=1")
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

        if shouldDispatchCommandPaletteHorizontalArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsCommandPaletteFieldEditor: firstResponderIsCommandPaletteFieldEditor,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
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

        if shouldDispatchTextBoxInputArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsTextBoxInput: firstResponderIsTextBoxInput,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
        ) {
            guard let target = self.firstResponder,
                  cmuxForceDispatchKeyDownOnce(event, to: target, reason: "text-box input arrow")
            else {
                return false
            }
            return true
        }

        if shouldDispatchTextBoxInputControlNavViaFirstResponderKeyDown(
            charactersIgnoringModifiers: KeyboardLayout.normalizedCharacters(for: event),
            firstResponderIsTextBoxInput: firstResponderIsTextBoxInput,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
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
        if shouldDispatchEditableTextViewArrowViaFirstResponderKeyDown(
            keyCode: event.keyCode,
            firstResponderIsEditableTextView: firstResponderIsStandaloneEditableTextView,
            firstResponderHasMarkedText: firstResponderHasMarkedText,
            flags: event.modifierFlags
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
               browserOmnibarPanelId(for: self.firstResponder) == nil,
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
                    "zoom.shortcut stage=window.mainMenuBypass event=\(Self.keyDescription(event)) " +
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

    static func keyDescription(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { parts.append("Cmd") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.option) { parts.append("Opt") }
        if flags.contains(.control) { parts.append("Ctrl") }
        let chars: String
        if event.type == .keyDown || event.type == .keyUp {
            chars = event.charactersIgnoringModifiers ?? "?"
        } else {
            chars = String(describing: event.type)
        }
        parts.append("'\(chars)'(\(event.keyCode))")
        return parts.joined(separator: "+")
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
        if browserOmnibarPanelId(for: responder) != nil {
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
        if let webView {
            objc_setAssociatedObject(
                fieldEditor,
                &cmuxFieldEditorOwningWebViewAssociationKey,
                CmuxFieldEditorOwningWebViewBox(webView: webView),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        } else {
            objc_setAssociatedObject(
                fieldEditor,
                &cmuxFieldEditorOwningWebViewAssociationKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    private static func cmuxTrackedOwningWebView(for fieldEditor: NSTextView) -> CmuxWebView? {
        guard let box = objc_getAssociatedObject(
            fieldEditor,
            &cmuxFieldEditorOwningWebViewAssociationKey
        ) as? CmuxFieldEditorOwningWebViewBox else {
            return nil
        }
        guard let webView = box.webView else {
            cmuxTrackFieldEditor(fieldEditor, owningWebView: nil)
            return nil
        }
        return webView
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
        TerminalController.shared.stop()
        NSApp.invalidateRestorableState()
        for window in NSApp.windows {
            window.invalidateRestorableState()
        }
    }

    func attemptUpdate() {
        attemptUpdate(nil)
    }

    var updateLogPath: String {
        updateLog.logPath()
    }
}

// MARK: - Window display placement (`window.display` / `window.displays`)

extension AppDelegate {
    /// A connected display, surfaced by the `window.displays` control command and
    /// the `cmux window display --list` CLI so callers can discover screen names.
    /// Lifted to ``CmuxWindowing/DisplayInfo``; aliased so existing
    /// `AppDelegate.DisplayInfo` references stay source-identical.
    typealias DisplayInfo = CmuxWindowing.DisplayInfo

    /// All currently-connected displays, in `NSScreen.screens` order.
    func availableDisplays() -> [DisplayInfo] {
        let mainID = NSScreen.main?.cmuxDisplayID
        return NSScreen.screens.enumerated().map { index, screen in
            let displayID = screen.cmuxDisplayID
            return DisplayInfo(
                name: screen.localizedName,
                index: index,
                displayID: displayID,
                isMain: displayID != nil && displayID == mainID,
                frame: screen.frame
            )
        }
    }

    /// Resolve a display from a query: case-insensitive exact name, then
    /// case-insensitive substring, then a zero-based index string. Returns nil
    /// when nothing matches so callers can report the available names.
    func screenMatching(_ query: String) -> NSScreen? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let screens = NSScreen.screens
        if let exact = screens.first(where: {
            $0.localizedName.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exact
        }
        let lowered = trimmed.lowercased()
        if let partial = screens.first(where: { $0.localizedName.lowercased().contains(lowered) }) {
            return partial
        }
        if let index = Int(trimmed), index >= 0, index < screens.count {
            return screens[index]
        }
        return nil
    }

    /// Move a single main window onto the display matched by `query`, preserving
    /// its size. Returns the resolved display name, or nil when the window or the
    /// display can't be resolved.
    @discardableResult
    func moveMainWindow(windowId: UUID, toDisplayMatching query: String) -> String? {
        guard let window = windowForMainWindowId(windowId),
              let screen = screenMatching(query) else { return nil }
        repositionPreservingSize(window, onto: screen)
        return screen.localizedName
    }

    /// Move every main window onto the display matched by `query`, preserving
    /// sizes. Returns the resolved display name and the moved window ids, or nil
    /// when the display can't be resolved.
    func moveAllMainWindows(toDisplayMatching query: String) -> (display: String, windowIds: [UUID])? {
        guard let screen = screenMatching(query) else { return nil }
        var moved: [UUID] = []
        for summary in listMainWindowSummaries() {
            guard let window = windowForMainWindowId(summary.windowId) else { continue }
            repositionPreservingSize(window, onto: screen)
            moved.append(summary.windowId)
        }
        return (screen.localizedName, moved)
    }

    /// Reposition `window` so it sits fully inside `screen`, keeping its current
    /// size (clamped to the display) and centering it. Deliberately does NOT
    /// raise, key, or activate the window: `window.display` is not a focus-intent
    /// command, so it must never steal macOS focus (see `focusIntentV2Methods`).
    func repositionPreservingSize(_ window: NSWindow, onto screen: NSScreen) {
        let visible = screen.visibleFrame
        let width = min(window.frame.width, visible.width)
        let height = min(window.frame.height, visible.height)
        var origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        origin.x = max(visible.minX, min(origin.x, visible.maxX - width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - height))
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: height).integral
        window.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - CmuxAppKitSupportUI seam conformance

extension AppDelegate: WindowDecorating {}
