public import AppKit
public import CmuxNextDesignTokens

/// How Chromium pages are shown (plans/cmux-next/in-tree-pages.md, cef-helper-app-DESIGN.md 3.3, 3.7 and 4). Three
/// modes, one for the whole process:
///
/// - ``Presentation/childWindow``: each page is a Chromium child window over its pane (layer hosted since 2026-11-06).
/// - ``Presentation/inTree``: the page's own view (`RenderWidgetHostViewCocoa`) is a subview of its pane in the cmux
///   window (fork API 36), so no page, overlay or divider catcher is a window of its own.
/// - ``Presentation/presented``: Chromium owns the page and exactly one window, its own, headless from the attach on
///   and never ordered in or key (fork API 30 detached hosting). cmux owns everything on screen: the page's pixels come
///   from that window's Core Animation context through a `CALayerHost` in cmux's own page view (fork API 26), which is
///   the page's only input surface and forwards to it; page focus is a cmux value (`cmux_browser_set_embedder_active`).
///   No Chromium view is in a cmux window and nothing in Chromium reads one. The in-process step of the helper app.
///
/// Decided once at launch (``latch(fileOverride:tag:environment:)``) and never again, so no page is ever in a mixed
/// state: a change applies at the next launch.
///
/// - ``requested``: from `CMUX_PAGE_PRESENTATION` (`presented`, `inTree`, `childWindow`), else `CMUX_IN_TREE_PAGES`
///   (`1` in tree, `0` child window; benches), else the Debug Settings file's `browser.pagePresentation` (or the older
///   `browser.inTreePages` switch), else the build's default (a dev build tagged `presented-pages…` presents, one tagged
///   `in-tree-pages…` is in tree, any other has child windows).
/// - ``mode``: requested, when the engine has the mode's calls (in tree: fork API 36; presented: API 26 and 30). With an
///   older engine the mode falls back to child windows (``engine`` says why) and every window-side part goes back too.
///
/// What reads it: the overlay host and the divider handles (``hasNoPageWindows``: in-window overlays, scroll goes to the
/// pane beside a divider), the window's responder gate (``isActive``, in tree only: ``InTreePageFocus``), and the
/// browser (pages in the tree, or presented).
@MainActor
public final class InTreePages {
    /// The process's one mode.
    public static let shared = InTreePages()

    init() {}

    /// How the process shows Chromium pages.
    public nonisolated enum Presentation: String, Sendable, CaseIterable, TunableChoice {
        /// A Chromium child window over each pane.
        case childWindow
        /// Chromium's page view in the pane, in the cmux window (fork API 36).
        case inTree
        /// cmux's page view shows the page's headless window by layer hosting and forwards input (fork API 26 and 30).
        case presented

        public var tunableTitle: String {
            switch self {
            case .childWindow: "Child windows"
            case .inTree: "In the window's view tree"
            case .presented: "Presented by cmux"
            }
        }

        /// The mode a name gives (`presented`, `inTree`, `childWindow`; snake and kebab case too); nil for another.
        public init?(name: String) {
            switch name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
            case "presented", "present": self = .presented
            case "intree": self = .inTree
            case "childwindow", "childwindows", "off": self = .childWindow
            default: return nil
            }
        }

        /// `debug.cef` / `debug.layers` name.
        public var debugName: String {
            switch self {
            case .childWindow: "child_window"
            case .inTree: "in_tree"
            case .presented: "presented"
            }
        }
    }

    /// Whether the engine can show pages in the requested mode.
    public enum Engine: Equatable, Sendable {
        /// Chromium has not loaded yet: no page exists, so nothing differs.
        case unknown
        /// The engine has the mode's calls.
        case supported
        /// The engine lacks them (the reason, for `debug.cef`): pages stay child windows.
        case unsupported(String)
    }

    public static let section = TunableSection(id: "browserInTree", title: "Chromium Page Presentation",
                                               symbol: "rectangle.inset.filled", order: 44)

    /// The Debug Settings key of the mode. Read once at launch: a change applies at the next launch. Readable off the
    /// main actor (the launch reads the file before the store).
    public nonisolated static let key = "browser.pagePresentation"
    /// The older on/off switch's key (`true`: in tree, `false`: child windows), still read from a file that has no
    /// ``key``.
    public nonisolated static let legacyKey = "browser.inTreePages"

    /// The row's default is this build's own decision without a file override (the environment, then the build tag), so
    /// the row shows the mode the build runs in: a build tagged `presented-pages…` shows Presented, and a file override
    /// still differs from it (the row's dot, Reset).
    public static let tunable = Tunable<Presentation>(
        descriptor: TunableDescriptor(
            key: key, section: section, label: "How Chromium pages show",
            help: "Child windows: a Chromium window over each pane. In the window's view tree: Chromium's page view inside its pane (fork API 36). Presented by cmux: cmux's own page view shows the page's headless Chromium window and forwards input to it, with no Chromium view or window in the cmux window (fork API 26 and 30). Applies at the next launch; an engine without the calls keeps child windows. The default is this build's own (CMUX_PAGE_PRESENTATION, else CMUX_IN_TREE_PAGES, else the build tag: presented-pages presents, in-tree-pages is in tree).",
            kind: .choice(Presentation.tunableOptions),
            defaultSource: .derived { .choice(InTreePages.shared.buildDefault.rawValue) }, codeName: "InTreePages.tunable"),
        defaultValue: .childWindow)

    public static var all: [TunableDescriptor] { [tunable.descriptor] }

    /// The environment variable that names the mode before everything else (`presented`, `inTree`, `childWindow`).
    public nonisolated static let presentationEnvironmentKey = "CMUX_PAGE_PRESENTATION"
    /// The older environment switch (`1` in tree, `0` child windows), read after ``presentationEnvironmentKey``.
    public nonisolated static let environmentKey = "CMUX_IN_TREE_PAGES"
    /// A dev build whose tag starts with this has pages in tree unless its Debug Settings file says otherwise.
    public nonisolated static let defaultOnTagPrefix = "in-tree-pages"
    /// A dev build whose tag starts with this presents its pages unless its Debug Settings file says otherwise.
    public nonisolated static let presentedTagPrefix = "presented-pages"

    /// The latched mode; nil until ``latch(fileOverride:tag:environment:)`` (or the first read) ran.
    private var latched: Presentation?
    /// What this build decides with no file override (the environment, then the tag): the row's default.
    public private(set) var buildDefault = Presentation.childWindow
    /// Where the latched value came from: `environment`, `file`, `tag` or `default`.
    public private(set) var source = "default"
    /// The engine's support for the requested mode, once Chromium loaded.
    public private(set) var engine = Engine.unknown

    /// Posted (object nil) when ``mode`` changed: the engine turned out to lack the calls.
    public static let activeDidChange = Notification.Name("cmux.inTreePages.activeDidChange")

    /// Decides the mode for this launch. The first call wins; later calls change nothing.
    ///
    /// - Parameters:
    ///   - fileOverride: The mode the Debug Settings file holds at launch (nil: no override).
    ///   - tag: The build's dev tag, if any.
    ///   - environment: The process environment.
    public func latch(fileOverride: Presentation?, tag: String?,
                      environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard latched == nil else { return }
        buildDefault = Self.decide(fileOverride: nil, tag: tag, environment: environment).0
        let (value, from) = Self.decide(fileOverride: fileOverride, tag: tag, environment: environment)
        latched = value
        source = from
    }

    /// The decision ``latch(fileOverride:tag:environment:)`` makes, without latching it (tests).
    public nonisolated static func decide(fileOverride: Presentation?, tag: String?,
                                          environment: [String: String]) -> (Presentation, String) {
        if let named = environment[presentationEnvironmentKey].flatMap(Presentation.init(name:)) { return (named, "environment") }
        switch environment[environmentKey] {
        case "1", "true", "on": return (.inTree, "environment")
        case "0", "false", "off": return (.childWindow, "environment")
        default: break
        }
        if let fileOverride { return (fileOverride, "file") }
        if let tag, tag.hasPrefix(presentedTagPrefix) { return (.presented, "tag") }
        if let tag, tag.hasPrefix(defaultOnTagPrefix) { return (.inTree, "tag") }
        return (.childWindow, "default")
    }

    /// The mode a Debug Settings file's values give: ``key``'s choice, else ``legacyKey``'s switch; nil for neither.
    public nonisolated static func fileOverride(in values: [String: Any]) -> Presentation? {
        if let raw = values[key] as? String, let mode = Presentation(rawValue: raw) ?? Presentation(name: raw) { return mode }
        if let on = values[legacyKey] as? Bool { return on ? .inTree : .childWindow }
        return nil
    }

    /// The mode asked for this launch (latched at the first read when nothing latched it before).
    public var requested: Presentation {
        if let latched { return latched }
        latch(fileOverride: nil, tag: nil)
        return latched ?? .childWindow
    }

    /// The mode pages are in: the requested one, unless the engine turned out to lack its calls (child windows then).
    public var mode: Presentation {
        let asked = requested
        if asked == .childWindow { return .childWindow }
        if case .unsupported = engine { return .childWindow }
        return asked
    }

    /// Whether in-tree pages were asked for this launch.
    public var isRequested: Bool { requested == .inTree }

    /// Whether pages are in the tree in this process (in-tree paths only: the responder gate, the in-tree hosting).
    public var isActive: Bool { mode == .inTree }

    /// Whether pages are presented by cmux in this process (``Presentation/presented``).
    public var isPresented: Bool { mode == .presented }

    /// Whether no page is a window over the cmux window (in tree or presented): overlays stay in the window, no divider
    /// catcher, choosers and JS dialogs go to the app.
    public var hasNoPageWindows: Bool { mode != .childWindow }

    /// The browser read the engine's support for the requested mode once Chromium loaded.
    public func engineResolved(_ resolved: Engine) {
        guard engine != resolved else { return }
        let was = mode
        engine = resolved
        if mode != was { NotificationCenter.default.post(name: Self.activeDidChange, object: nil) }
    }

    /// `debug.cef` / `debug.layers` `in_tree`: `off`, `on`, `pending` (on, the engine not loaded yet) or
    /// `unsupported_fork: <reason>`. `off` in every mode but in tree.
    public var status: String {
        guard isRequested else { return "off" }
        return engineStatus(on: "on")
    }

    /// `debug.cef` / `debug.layers` `page_presentation`: the mode's name (``Presentation/debugName``), `pending: <name>`
    /// before the engine loaded, or `unsupported_fork: <reason>` (pages are child windows then).
    public var presentationStatus: String {
        let asked = requested
        guard asked != .childWindow else { return asked.debugName }
        return engineStatus(on: asked.debugName, pending: "pending: \(asked.debugName)")
    }

    private func engineStatus(on: String, pending: String = "pending") -> String {
        switch engine {
        case .unknown: return pending
        case .supported: return on
        case .unsupported(let reason): return "unsupported_fork: \(reason)"
        }
    }

    #if DEBUG
    /// Tests set the mode directly (the latch keeps the first value otherwise): `true` in tree, `false` child windows,
    /// nil unlatched.
    public func setForTesting(requested: Bool?, engine: Engine = .unknown) {
        setForTesting(mode: requested.map { $0 ? .inTree : .childWindow }, engine: engine)
    }

    /// Tests set the mode directly (nil: unlatched).
    public func setForTesting(mode: Presentation?, engine: Engine = .unknown) {
        latched = mode
        buildDefault = .childWindow
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

    /// `path` acted; counted only while pages have no page windows (in tree, or presented).
    public func fired(_ path: Path) {
        guard InTreePages.shared.hasNoPageWindows else { return }
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
