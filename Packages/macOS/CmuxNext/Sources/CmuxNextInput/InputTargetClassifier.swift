public import AppKit
public import CmuxNextInputCore

/// Which surface an input lands in, for its latency slot's ``CmuxNextInputCore/InputTarget``, so each
/// surface gets its own EventLatency rows (Chrome splits its histograms by the frame's source the same way,
/// cc/metrics/event_latency_tracing_recorder.cc).
///
/// The App's composition root lists the rules, most specific first; an input gets the target of the first rule that
/// any view on its path (the view up to its window's root) or its window matches. A terminal therefore stays a
/// terminal inside the layout, an agent pane's web view is the agent pane, not a WebKit page, and an agent pane's
/// Chromium page window (a `CefNSWindow` child of the cmux window, outside the pane's views) is the agent pane too,
/// through the page rule's `owner`:
///
/// ```swift
/// let classifier = InputTargetClassifier(rules: [
///     .view(TerminalSurfaceView.self, is: .terminal),
///     .view(AgentPaneView.self, is: .agentPane),
///     .windowClassNamed("CefNSWindow", is: .chromiumPage, owner: { page in agentPaneOwns(page) ? .agentPane : nil }),
///     .view(WKWebView.self, is: .webkitPage),
///     .textInputClient(is: .textView),
///     .view(LayoutRootView.self, is: .layout),
/// ])
/// ```
///
/// A key's target is its window's first responder, cached by responder and its superview, so typing pays a few
/// identity checks; the window's field editor, which AppKit moves from field to field, is classified each time. A
/// pointer event's target is the view under it (one hit test, which the caller makes once per click or scroll
/// gesture).
@MainActor
public final class InputTargetClassifier {
    /// The surface a window of a named class belongs to when it is not the rule's own target (an agent pane's
    /// Chromium page); nil keeps the rule's target.
    public typealias WindowOwner = @MainActor (NSWindow) -> InputTarget?

    /// One way a view or a window names its surface.
    public struct Rule {
        enum Match {
            case view(AnyClass)
            case window(AnyClass)
            /// A window class from a framework that loads later (Chromium's `CefNSWindow`), found by name.
            case windowNamed(String, owner: WindowOwner?)
            case textInputClient
        }

        let match: Match
        /// The surface an input matched by this rule lands in.
        public let target: InputTarget

        /// Views of `type` (and subclasses), and every view inside one, are `target`.
        public static func view(_ type: AnyClass, is target: InputTarget) -> Rule {
            Rule(match: .view(type), target: target)
        }

        /// Every view of a window of `type` (or a subclass) is `target`.
        public static func window(_ type: AnyClass, is target: InputTarget) -> Rule {
            Rule(match: .window(type), target: target)
        }

        /// ``window(_:is:)`` for the Objective-C class `name`, which may load after launch.
        ///
        /// - Parameters:
        ///   - name: The window class's Objective-C name.
        ///   - target: The surface of its windows.
        ///   - owner: The surface a window of the class belongs to instead, or nil for `target`. Asked once per
        ///     window in a row (the last answer is kept for the same window).
        public static func windowClassNamed(_ name: String, is target: InputTarget, owner: WindowOwner? = nil) -> Rule {
            Rule(match: .windowNamed(name, owner: owner), target: target)
        }

        /// A view that takes text input (`NSTextInputClient`: text views, fields' editors) is `target`.
        public static func textInputClient(is target: InputTarget) -> Rule {
            Rule(match: .textInputClient, target: target)
        }
    }

    private let rules: [Rule]
    /// Each rule's class: the view or window class, or a named window class once it is loaded.
    private var classes: [AnyClass?]
    /// Per named-class rule not resolved yet, the window class it last missed on: the name is looked up again only
    /// for a window of another class (the first `CefNSWindow` after Chromium loads), not on every event.
    private var missedWindowClasses: [ObjectIdentifier?]
    private weak var cachedResponder: NSResponder?
    private weak var cachedSuperview: NSView?
    private weak var cachedWindow: NSWindow?
    private var cachedTarget = InputTarget.other
    /// The last window a named rule's `owner` was asked about, and its answer.
    private weak var ownedWindow: NSWindow?
    private var ownedTarget: InputTarget?

    /// - Parameter rules: The surfaces, most specific first.
    public init(rules: [Rule]) {
        self.rules = rules
        classes = rules.map { rule -> AnyClass? in
            switch rule.match {
            case let .view(type), let .window(type): type
            case let .windowNamed(name, _): NSClassFromString(name)
            case .textInputClient: nil
            }
        }
        missedWindowClasses = Array(repeating: nil, count: rules.count)
    }

    /// The target of a key typed into `window`: the surface of its first responder.
    // perf-hot: 0.2us key-dispatch
    public func keyTarget(in window: NSWindow?) -> InputTarget {
        guard let window else { return .other }
        let responder = window.firstResponder
        let view = responder as? NSView
        // The field editor is one text view per window that AppKit moves into whichever field is being edited.
        let isFieldEditor = (responder as? NSTextView)?.isFieldEditor == true
        if !isFieldEditor, let responder, responder === cachedResponder, view?.superview === cachedSuperview,
           window === cachedWindow {
            return cachedTarget
        }
        let target = classify(view: view, in: window)
        guard !isFieldEditor else { return target }
        cachedResponder = responder
        cachedSuperview = view?.superview
        cachedWindow = window
        cachedTarget = target
        return target
    }

    /// The target of a pointer event: the surface of the view under it in its window.
    public func pointerTarget(of event: NSEvent) -> InputTarget {
        guard let window = event.window else { return .other }
        return classify(view: Self.view(at: event.locationInWindow, in: window), in: window)
    }

    /// The surface of `view` in `window`: the first rule that a view from `view` up to its root, or `window`, matches.
    public func classify(view: NSView?, in window: NSWindow?) -> InputTarget {
        var best = rules.count
        var current = view
        while let candidate = current, best > 0 {
            for index in 0..<best where matches(index, view: candidate) {
                best = index
                break
            }
            current = candidate.superview
        }
        if let window {
            for index in 0..<best {
                if let target = target(of: index, window: window) { return target }
            }
        }
        return best < rules.count ? rules[best].target : .other
    }

    /// The deepest view at `point` (window coordinates) in `window`, as AppKit's own hit test finds it.
    static func view(at point: NSPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView else { return nil }
        // The root of the window's views (the frame view) takes window coordinates; with none, the content view does.
        return (content.superview ?? content).hitTest(point)
    }

    private func matches(_ index: Int, view: NSView) -> Bool {
        switch rules[index].match {
        case .view:
            guard let type = classes[index] else { return false }
            return view.isKind(of: type)
        case .textInputClient:
            return view is any NSTextInputClient
        case .window, .windowNamed:
            return false
        }
    }

    /// The target `window` gets from rule `index`, or nil when the rule does not match it.
    private func target(of index: Int, window: NSWindow) -> InputTarget? {
        switch rules[index].match {
        case .window:
            guard let type = classes[index], window.isKind(of: type) else { return nil }
            return rules[index].target
        case let .windowNamed(name, owner):
            guard let type = namedClass(index, name: name, for: window), window.isKind(of: type) else { return nil }
            guard let owner else { return rules[index].target }
            if window !== ownedWindow {
                ownedWindow = window
                ownedTarget = owner(window)
            }
            return ownedTarget ?? rules[index].target
        case .view, .textInputClient:
            return nil
        }
    }

    /// Rule `index`'s class `name`, looked up again only when `window`'s class is not the one it last missed on.
    private func namedClass(_ index: Int, name: String, for window: NSWindow) -> AnyClass? {
        if let type = classes[index] { return type }
        let windowClass = ObjectIdentifier(type(of: window))
        guard missedWindowClasses[index] != windowClass else { return nil }
        guard let type = NSClassFromString(name) else {
            missedWindowClasses[index] = windowClass
            return nil
        }
        classes[index] = type
        return type
    }
}
