public import AppKit
public import CmuxNextInputCore

/// Which surface an input lands in, for its latency slot's ``CmuxNextInputCore/InputTarget`` (p04-input-005), so each
/// surface gets its own EventLatency rows (Chrome splits its histograms by the frame's source the same way,
/// cc/metrics/event_latency_tracing_recorder.cc).
///
/// The App's composition root lists the rules, most specific first; an input gets the target of the first rule that
/// any view on its path (the view up to its window's root) or its window matches. A terminal therefore stays a
/// terminal inside the layout, and an agent pane's web view is the agent pane, not a WebKit page:
///
/// ```swift
/// let classifier = InputTargetClassifier(rules: [
///     .view(TerminalSurfaceView.self, is: .terminal),
///     .view(AgentPaneView.self, is: .agentPane),
///     .windowClassNamed("CefNSWindow", is: .chromiumPage),
///     .view(WKWebView.self, is: .webkitPage),
///     .textInputClient(is: .textView),
///     .view(LayoutRootView.self, is: .layout),
/// ])
/// ```
///
/// A key's target is its window's first responder, cached by responder, so typing pays one identity check. A pointer
/// event's target is the view under it (one hit test, which the caller makes once per click or scroll gesture).
@MainActor
public final class InputTargetClassifier {
    /// One way a view or a window names its surface.
    public struct Rule {
        enum Match {
            case view(AnyClass)
            case window(AnyClass)
            /// A window class from a framework that loads later (Chromium's `CefNSWindow`), found by name.
            case windowNamed(String)
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

        /// ``window(_:is:)`` for the Objective-C class `name`, looked up until it is loaded.
        public static func windowClassNamed(_ name: String, is target: InputTarget) -> Rule {
            Rule(match: .windowNamed(name), target: target)
        }

        /// A view that takes text input (`NSTextInputClient`: text views, fields' editors) is `target`.
        public static func textInputClient(is target: InputTarget) -> Rule {
            Rule(match: .textInputClient, target: target)
        }
    }

    private let rules: [Rule]
    /// Each rule's class: the view or window class, or a named window class once it is loaded.
    private var classes: [AnyClass?]
    private weak var cachedResponder: NSResponder?
    private weak var cachedWindow: NSWindow?
    private var cachedTarget = InputTarget.other

    /// - Parameter rules: The surfaces, most specific first.
    public init(rules: [Rule]) {
        self.rules = rules
        classes = rules.map { rule -> AnyClass? in
            switch rule.match {
            case let .view(type), let .window(type): type
            case let .windowNamed(name): NSClassFromString(name)
            case .textInputClient: nil
            }
        }
    }

    /// The target of a key typed into `window`: the surface of its first responder.
    // perf-hot: 0.2us key-dispatch
    public func keyTarget(in window: NSWindow?) -> InputTarget {
        guard let window else { return .other }
        let responder = window.firstResponder
        if let responder, responder === cachedResponder, window === cachedWindow { return cachedTarget }
        let target = classify(view: responder as? NSView, in: window)
        cachedResponder = responder
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
        if let window, best > 0 {
            for index in 0..<best where matches(index, window: window) {
                best = index
                break
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

    private func matches(_ index: Int, window: NSWindow) -> Bool {
        switch rules[index].match {
        case .window:
            break
        case let .windowNamed(name):
            if classes[index] == nil { classes[index] = NSClassFromString(name) }
        case .view, .textInputClient:
            return false
        }
        guard let type = classes[index] else { return false }
        return window.isKind(of: type)
    }
}
