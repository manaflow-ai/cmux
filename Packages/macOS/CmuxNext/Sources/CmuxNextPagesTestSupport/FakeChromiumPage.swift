public import AppKit
public import CmuxNextPages
public import Foundation

/// A ``PageChromiumPage`` that records the host's calls, for tests of anything that shows a page in
/// Chromium.
///
/// It is the one test double of ``PageChromiumPage``: when the protocol gains a requirement, this
/// file is the only one to change, and the protocol's own test target (`CmuxNextPagesTests`)
/// compiles it. A test that needs a special answer sets ``answer`` instead of writing its own
/// conformance (a private copy missed `setSeeThrough(_:)` and broke the test build, 2026-10-21).
///
/// ```swift
/// let hosting = FakeChromiumHosting()
/// let page = FakeChromiumPage()
/// page.answer = { method, _ in method == "Runtime.evaluate" ? #"{"result":{}}"# : nil }
/// ```
@MainActor
public final class FakeChromiumPage: PageChromiumPage {
    /// The view the host places where the page shows.
    public let contentView = NSView()
    /// The handler the host sets for the page's events.
    public var onEvent: ((PageChromiumEvent) -> Void)?
    /// The answerer the host sets for the page's dynamic paths.
    public var resources: (@MainActor (URL) async -> PageChromiumResponse)?
    /// The holes the host last asked for, in ``contentView``'s coordinates.
    public var occlusionRects: [CGRect] = []
    /// Every DevTools call, in order.
    public private(set) var calls: [(method: String, params: [String: any Sendable])] = []
    /// Every URL the host loaded, in order.
    public private(set) var loaded: [URL] = []
    /// The last zoom the host set; nil before any.
    public private(set) var zoom: Double?
    /// Whether the host closed the page.
    public private(set) var closed = false
    /// Every visibility value requested by the host.
    public private(set) var visibility: [Bool] = []
    /// The last ``setAnswersFileChooser(_:)``; nil before any.
    public private(set) var answersFileChooser: Bool?
    /// The last ``setSeeThrough(_:)``; nil before any.
    public private(set) var seeThrough: Bool?
    /// ``seeThrough`` when the first document loaded.
    public private(set) var seeThroughAtFirstLoad: Bool??
    /// The URL the sender check (`[location.href, window === window.top]`) answers.
    public var senderURL = "cmux-page://test.plain/index.html"
    /// Whether the sender check answers that the sender is the top frame.
    public var senderIsTop = true
    /// Runs after each call (tests wait on it).
    public var onCall: (() -> Void)?
    /// Answers a call by its method and params before the defaults (nil: the defaults answer).
    public var answer: ((_ method: String, _ params: [String: any Sendable]) -> String?)?
    /// Runs when the host closes the page.
    public var onClose: (() -> Void)?

    /// Makes a page with no calls yet.
    public init() {}

    /// Records the call and answers it: ``answer`` first, then the sender check, then an empty result.
    public func devTools(_ method: String, params: [String: any Sendable]) async throws -> String {
        calls.append((method, params))
        defer { onCall?() }
        if let answered = answer?(method, params) { return answered }
        if method == "Page.addScriptToEvaluateOnNewDocument" { return #"{"identifier":"test-script"}"# }
        if method == "Runtime.evaluate", params["expression"] as? String == "[location.href, window === window.top]" {
            return #"{"result":{"type":"object","value":["\#(senderURL)",\#(senderIsTop)]}}"#
        }
        return #"{"result":{}}"#
    }

    /// Records `url` in ``loaded``.
    public func load(_ url: URL) {
        if loaded.isEmpty { seeThroughAtFirstLoad = .some(seeThrough) }
        loaded.append(url)
    }

    /// Records the value in ``seeThrough``.
    public func setSeeThrough(_ seeThrough: Bool) { self.seeThrough = seeThrough }
    /// Records the value in ``answersFileChooser``.
    public func setAnswersFileChooser(_ on: Bool) { answersFileChooser = on }
    /// How often the page was reloaded.
    public private(set) var reloads = 0
    /// Counts the reload in ``reloads``.
    public func reload() { reloads += 1 }
    /// Records the value in ``zoom``.
    public func setZoom(_ zoom: Double) { self.zoom = zoom }
    /// Every focus ask, in order.
    public private(set) var focusAsks: [Bool] = []
    /// Records the ask in ``focusAsks``.
    public func setFocused(_ focused: Bool) { focusAsks.append(focused) }
    /// Does nothing.
    public func setVisible(_ visible: Bool) { visibility.append(visible) }

    /// Sets ``closed`` and runs ``onClose``.
    public func close() {
        closed = true
        onClose?()
    }
}
