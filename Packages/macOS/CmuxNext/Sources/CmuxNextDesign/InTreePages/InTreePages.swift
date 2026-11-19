public import AppKit
public import CmuxNextDesignTokens

/// In-tree Chromium pages (plans/cmux-next/in-tree-pages.md): the mode in which a Chromium page's own view
/// (`RenderWidgetHostViewCocoa`) is a subview of its pane in the cmux window, so no page, overlay or divider catcher
/// is a window of its own.
///
/// One switch for the whole process, decided once at launch (``latch(fileOverride:tag:environment:)``) and never
/// again, so no page is ever in a mixed state: a change applies at the next launch.
///
/// - ``isRequested``: the switch, from `CMUX_IN_TREE_PAGES` (`1` or `0`, for benches), else the Debug Settings file's
///   `browser.inTreePages`, else the build's default (on only for a dev build tagged `in-tree-pages…`).
/// - ``isActive``: requested, and the engine has the fork's in-tree API (API 36). With an older engine the mode falls
///   back to child-window pages (``engine`` says why) and every window-side part goes back to today's path too.
///
/// What reads it: the overlay host (in-window overlays, no `OverlayHostPanel`), the divider handles (scroll goes to the
/// pane beside the divider), the window's responder gate (``InTreePageFocus``), and the browser (pages in the tree).
@MainActor
public final class InTreePages {
    /// The process's one mode.
    public static let shared = InTreePages()

    init() {}

    /// Whether the engine can host pages in the tree.
    public enum Engine: Equatable, Sendable {
        /// Chromium has not loaded yet: no page exists, so nothing differs.
        case unknown
        /// The engine has the in-tree calls (fork API 36).
        case supported
        /// The engine lacks them (the reason, for `debug.cef`): pages stay child windows.
        case unsupported(String)
    }

    public static let section = TunableSection(id: "browserInTree", title: "Chromium In-Tree Pages",
                                               symbol: "rectangle.inset.filled", order: 44)

    /// The Debug Settings switch. Read once at launch: a change applies at the next launch.
    public static let tunable = Tunable<Bool>.toggle(
        "browser.inTreePages", section, "Pages in the window's view tree",
        help: "Chromium pages draw as views inside their pane, with overlays and dividers as plain views: no page, overlay or divider windows. Applies at the next launch. Needs fork API 36; an older engine keeps child-window pages.",
        default: false, code: "InTreePages.tunable")

    public static var all: [TunableDescriptor] { [tunable.descriptor] }

    /// The environment variable that decides the switch before the Debug Settings file (`1` or `0`).
    public static let environmentKey = "CMUX_IN_TREE_PAGES"
    /// A dev build whose tag starts with this has the switch on unless its Debug Settings file turns it off.
    public static let defaultOnTagPrefix = "in-tree-pages"

    /// The latched switch; nil until ``latch(fileOverride:tag:environment:)`` (or the first read) ran.
    private var latched: Bool?
    /// Where the latched value came from: `environment`, `file`, `tag` or `default`.
    public private(set) var source = "default"
    /// The engine's support, once Chromium loaded.
    public private(set) var engine = Engine.unknown

    /// Posted (object nil) when ``isActive`` changed: the engine turned out to lack the calls.
    public static let activeDidChange = Notification.Name("cmux.inTreePages.activeDidChange")

    /// Decides the switch for this launch. The first call wins; later calls change nothing.
    ///
    /// - Parameters:
    ///   - fileOverride: `browser.inTreePages` as the Debug Settings file holds it at launch (nil: no override).
    ///   - tag: The build's dev tag, if any.
    ///   - environment: The process environment.
    public func latch(fileOverride: Bool?, tag: String?,
                             environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard latched == nil else { return }
        let (value, from) = Self.decide(fileOverride: fileOverride, tag: tag, environment: environment)
        latched = value
        source = from
    }

    /// The decision ``latch(fileOverride:tag:environment:)`` makes, without latching it (tests).
    public nonisolated static func decide(fileOverride: Bool?, tag: String?,
                                          environment: [String: String]) -> (Bool, String) {
        switch environment[Self.environmentKey] {
        case "1", "true", "on": return (true, "environment")
        case "0", "false", "off": return (false, "environment")
        default: break
        }
        if let fileOverride { return (fileOverride, "file") }
        if let tag, tag.hasPrefix(Self.defaultOnTagPrefix) { return (true, "tag") }
        return (false, "default")
    }

    /// Whether the switch is on for this launch (latched at the first read when nothing latched it before).
    public var isRequested: Bool {
        if let latched { return latched }
        latch(fileOverride: nil, tag: nil)
        return latched ?? false
    }

    /// Whether pages are in the tree in this process: requested, and the engine did not turn out to lack the calls.
    public var isActive: Bool {
        guard isRequested else { return false }
        if case .unsupported = engine { return false }
        return true
    }

    /// The browser read the engine's support once Chromium loaded.
    public func engineResolved(_ resolved: Engine) {
        guard engine != resolved else { return }
        let was = isActive
        engine = resolved
        if isActive != was { NotificationCenter.default.post(name: Self.activeDidChange, object: nil) }
    }

    /// `debug.cef` / `debug.layers` `in_tree`: `off`, `on`, `pending` (on, the engine not loaded yet) or
    /// `unsupported_fork: <reason>`.
    public var status: String {
        guard isRequested else { return "off" }
        switch engine {
        case .unknown: return "pending"
        case .supported: return "on"
        case .unsupported(let reason): return "unsupported_fork: \(reason)"
        }
    }

    #if DEBUG
    /// Tests set the mode directly (the latch keeps the first value otherwise).
    public func setForTesting(requested: Bool?, engine: Engine = .unknown) {
        latched = requested
        source = "test"
        self.engine = engine
    }
    #endif
}

/// How often each path that in-tree pages retire still acted while the mode was on (`debug.focus` `in_tree_guards`).
/// Every count must stay 0: a nonzero one shows a page window or a cross-window path still exists in the mode.
@MainActor
public final class InTreeRetiredGuards {
    public static let shared = InTreeRetiredGuards()

    init() {}

    /// `ChildPageFocus` gave, took or reclaimed a page window's keys.
    public private(set) var childPageFocus = 0
    /// `CrossWindowInputGuard` would have dropped a key (bypassed in the mode: the key is delivered).
    public private(set) var crossWindowInput = 0
    /// `UnseenKeyboardGuard` refused a move to a page window's view.
    public private(set) var unseenKeyboardPageWindow = 0
    /// The overlay host took an event from a window below its panel (`takeEventFromBelow`).
    public private(set) var takeEventFromBelow = 0
    /// A divider catcher panel was made or moved.
    public private(set) var dividerCatchers = 0

    public enum Path: String, CaseIterable, Sendable {
        case childPageFocus = "child_page_focus", crossWindowInput = "cross_window_input"
        case unseenKeyboardPageWindow = "unseen_keyboard_page_window", takeEventFromBelow = "take_event_from_below"
        case dividerCatchers = "divider_catchers"
    }

    /// `path` acted; counted only while the mode is on.
    public func fired(_ path: Path) {
        guard InTreePages.shared.isActive else { return }
        switch path {
        case .childPageFocus: childPageFocus += 1
        case .crossWindowInput: crossWindowInput += 1
        case .unseenKeyboardPageWindow: unseenKeyboardPageWindow += 1
        case .takeEventFromBelow: takeEventFromBelow += 1
        case .dividerCatchers: dividerCatchers += 1
        }
    }

    /// Every count by its path's name.
    public var counts: [String: Int] {
        [Path.childPageFocus.rawValue: childPageFocus, Path.crossWindowInput.rawValue: crossWindowInput,
         Path.unseenKeyboardPageWindow.rawValue: unseenKeyboardPageWindow,
         Path.takeEventFromBelow.rawValue: takeEventFromBelow, Path.dividerCatchers.rawValue: dividerCatchers]
    }
}
