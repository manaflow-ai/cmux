import AppKit
import os

/// What the app knows about one of its own windows when it appears, for the
/// last-resort guard against Chromium's own top-level windows.
struct ChromiumWindowFacts: Equatable, Sendable {
    /// Created by Chromium's views (`NativeWidgetMacNSWindow` or a subclass).
    var chromium: Bool
    /// A Chromium `Browser` window (`BrowserNativeWidgetWindow`): tab strip,
    /// toolbar, menus.
    var browserWindow: Bool
    /// A child window of another window (pages, docked DevTools, bubbles,
    /// menus, extension popups).
    var hasParent: Bool
    /// Has a title bar (a window, not a bubble, menu or video overlay).
    var titled: Bool
    var visible: Bool
    /// A DevTools window cmux allows (undocked DevTools).
    var devTools: Bool
    /// Above normal windows (picture-in-picture, which floats on purpose).
    var floating: Bool
}

enum ChromiumWindowVerdict: Equatable, Sendable {
    case allow
    /// Hide it at once. A Browser window is only hidden: its tabs move into a
    /// page and Chromium closes it when it is empty.
    case hide
    /// Hide and close it (Task Manager, feedback, profile picker and other
    /// Chromium dialogs with a title bar).
    case close
}

enum ChromiumWindowRule {
    static func verdict(_ facts: ChromiumWindowFacts) -> ChromiumWindowVerdict {
        guard facts.chromium, facts.visible, !facts.hasParent, facts.titled,
              !facts.devTools, !facts.floating else { return .allow }
        return facts.browserWindow ? .hide : .close
    }
}

/// Last line of defense against Chromium's own top-level windows (a `Browser`
/// window with Chromium's tab strip and toolbar, Task Manager, the feedback
/// dialog, the profile picker). The fork routes every window request to cmux
/// (fork API 8) and never shows a Browser it created on its own; this guard
/// covers any path the fork misses. It watches the app's windows as they
/// appear (key, main and occlusion changes) and applies `ChromiumWindowRule`.
@MainActor
final class ChromiumWindowGuard {
    private(set) var blockedCount = 0
    private var observers: [any NSObjectProtocol] = []
    private let logger: Logger
    private let allowsWindow: @MainActor (NSWindow) -> Bool
    private lazy var widgetClass: AnyClass? = NSClassFromString("NativeWidgetMacNSWindow")
    private lazy var browserWindowClass: AnyClass? = NSClassFromString("BrowserNativeWidgetWindow")

    init(logger: Logger, allowsWindow: @escaping @MainActor (NSWindow) -> Bool) {
        self.logger = logger
        self.allowsWindow = allowsWindow
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

    func facts(for window: NSWindow) -> ChromiumWindowFacts {
        let chromium = widgetClass.map { window.isKind(of: $0) } ?? false
        return ChromiumWindowFacts(
            chromium: chromium,
            browserWindow: browserWindowClass.map { window.isKind(of: $0) } ?? false,
            hasParent: window.parent != nil,
            titled: window.styleMask.contains(.titled),
            visible: window.isVisible,
            devTools: chromium && allowsWindow(window),
            floating: window.level.rawValue > NSWindow.Level.normal.rawValue
        )
    }

    private func check(_ window: NSWindow) {
        let verdict = ChromiumWindowRule.verdict(facts(for: window))
        guard verdict != .allow else { return }
        blockedCount += 1
        let className = NSStringFromClass(type(of: window))
        logger.error("Blocked a Chromium window (\(className, privacy: .public)) \"\(window.title, privacy: .public)\"")
        window.orderOut(nil)
        if verdict == .close { window.close() }
    }
}
