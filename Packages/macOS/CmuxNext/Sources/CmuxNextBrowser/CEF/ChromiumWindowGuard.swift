import AppKit
import os

/// Last line of defense against Chromium's own top-level windows (a
/// `Browser` window with Chrome's tab strip and toolbar, Task Manager, the
/// feedback dialog, the profile picker). The fork routes every window
/// request to cmux (fork API 8) and never shows a Browser it created on its
/// own; this guard covers older forks and any path the fork misses. It
/// watches the app's windows as they appear (key, main and occlusion
/// changes) and applies `ChromiumWindowRule`. Each block is logged and
/// counted (`debug.cef` `chromium_windows`).
final class ChromiumWindowGuard {
    struct Blocked: Equatable, Sendable {
        var className: String
        var title: String
        var verdict: ChromiumWindowVerdict
    }

    private(set) var blockedCount = 0
    /// The latest blocks, newest last (at most `recentLimit`).
    private(set) var recent: [Blocked] = []
    private let recentLimit = 8
    private var observers: [any NSObjectProtocol] = []
    private let logger: Logger
    /// True when `window` is a DevTools window cmux placed on purpose.
    private let isPlacedDevTools: (NSWindow) -> Bool
    private lazy var widgetClass: AnyClass? = NSClassFromString("NativeWidgetMacNSWindow")
    private lazy var browserWindowClass: AnyClass? = NSClassFromString("BrowserNativeWidgetWindow")

    init(logger: Logger, isPlacedDevTools: @escaping (NSWindow) -> Bool) {
        self.logger = logger
        self.isPlacedDevTools = isPlacedDevTools
    }

    /// Starts watching (after CefInitialize, when Chromium's classes exist).
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.check(window) }
            })
        }
        for window in NSApp.windows { check(window) }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func facts(for window: NSWindow) -> ChromiumWindowFacts {
        let chromium = widgetClass.map { window.isKind(of: $0) } ?? false
        return ChromiumWindowFacts(
            chromium: chromium,
            browserWindow: browserWindowClass.map { window.isKind(of: $0) } ?? false,
            hasParent: window.parent != nil,
            titled: window.styleMask.contains(.titled),
            visible: window.isVisible,
            devTools: chromium && isPlacedDevTools(window),
            floating: window.level.rawValue > NSWindow.Level.normal.rawValue
        )
    }

    /// Top-level Chromium windows with a title bar that are on screen now
    /// and would be blocked (a live check expects none).
    func offendingWindows() -> [NSWindow] {
        NSApp.windows.filter { ChromiumWindowRule.verdict(facts(for: $0)) != .allow }
    }

    private func check(_ window: NSWindow) {
        let verdict = ChromiumWindowRule.verdict(facts(for: window))
        guard verdict != .allow else { return }
        let blocked = Blocked(className: NSStringFromClass(type(of: window)), title: window.title, verdict: verdict)
        blockedCount += 1
        recent.append(blocked)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        logger.error("Blocked a Chromium window (\(blocked.className, privacy: .public)) \"\(blocked.title, privacy: .public)\"")
        window.orderOut(nil)
        if verdict == .close { window.close() }
    }
}
