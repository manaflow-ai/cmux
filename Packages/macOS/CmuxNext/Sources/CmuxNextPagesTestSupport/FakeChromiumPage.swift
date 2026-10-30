public import AppKit
import CmuxNextCompat
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
    /// The page channel event the page script fires; nil (the default) stands for an engine with no page channel.
    public var pageHostEvent: String?
    /// The holes the host last asked for, in ``contentView``'s coordinates.
    public var occlusionRects: [CGRect] = []
    /// The window ``isPageWindow(_:)`` answers for (a test's child window over the page); nil: none.
    public weak var pageWindow: NSWindow?
    /// Every DevTools call, in order.
    public private(set) var calls: [(method: String, params: [String: any Sendable])] = []
    /// Every URL the host loaded, in order.
    public private(set) var loaded: [URL] = []
    /// How many times the host reloaded the document (``reload()``; p13-webui-039 and p07-memory-049 both read it).
    public private(set) var reloads = 0
    /// The last zoom the host set; nil before any.
    public private(set) var zoom: Double?
    /// Whether the host closed the page.
    public private(set) var closed = false
    /// What ``discard()`` answers: false stands for a fork without in-place discard.
    public var discardAnswer = true
    /// How many times the host discarded the page (answered true).
    public private(set) var discards = 0
    /// A discard took and no load ran since (the engine reloads the entry when the page shows).
    public private(set) var isDiscarded = false
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
    /// When set, every DevTools call fails with it after ``answer`` ran (a page whose browser ended).
    public var devToolsFailure: (any Error)?
    /// Runs when the host closes the page.
    public var onClose: (() -> Void)?
    /// Whether the page is on the fork's renderer paths (no DevTools session).
    public var usesRendererPaths: Bool
    /// Every script ``evaluate(_:)`` ran, in order, whichever path answered it.
    public private(set) var evaluations: [String] = []
    /// Runs after each evaluation (tests wait on it).
    public var onEvaluate: (() -> Void)?
    /// The renderer path (`tabEvaluate`, fork API 29): when set, ``evaluate(_:)`` answers with it,
    /// as `tabEvaluate`'s text (`CEFEvaluationResult`): the value as JSON, empty for undefined;
    /// throw ``PageScriptError/exception(_:)`` for an exception. It makes no DevTools call. Nil: `null`
    /// on renderer paths (``usesRendererPaths``), else the DevTools path, a `Runtime.evaluate` in
    /// ``calls`` answered as any call is (``answer``).
    public var rendererEvaluate: ((_ script: String) throws -> String)?
    /// Awaited by ``evaluate(_:)`` after it records the script and before it answers: a test holds an
    /// answer back (a page call still in flight) until the gate returns. Nil: answers at once.
    public var evaluateGate: (@MainActor () async -> Void)?

    /// What ``copySurface(maxPixelSize:done:)`` answers; nil: no picture.
    public var surfaceCopy: PageSurfaceCopy?
    /// The size of every surface copy asked for, in order.
    public private(set) var surfaceCopies: [CGSize] = []
    /// What ``copiesSurface`` answers: false (the default) stands for a fork without the surface copy,
    /// where a picture goes through DevTools (``answer`` gives its `Page.captureScreenshot` reply).
    public var copiesSurface = false
    /// Whether ``sendClick(at:)`` clicks: false (the default) stands for a fork without the native
    /// click, where a click goes through DevTools input.
    public var nativeClicks = false
    /// Every native click the host sent (``sendClick(at:)``), in view points, in order.
    public private(set) var clicks: [CGPoint] = []
    /// Whether ``sendMouseMove(at:)`` moves: false (the default) stands for a fork without the native move,
    /// where a hover goes through DevTools input.
    public var nativeMoves = false
    /// Every native mouse move the host sent (``sendMouseMove(at:)``), in view points, in order.
    public private(set) var mouseMoves: [CGPoint] = []
    /// How many times the host copied the selection (``copySelection()``).
    public private(set) var selectionCopies = 0
    /// Every pane window the host moved the page to (``moveWindow(to:)``), in order.
    public private(set) var moves: [PageChromiumWindow] = []

    /// One visibility or lifecycle call the host made (``setVisible(_:)``, ``setFrozen(_:)``).
    public enum LifecycleStep: Equatable, Sendable {
        case visible(Bool)
        case frozen(Bool)
    }
    /// Every ``setVisible(_:)`` and ``setFrozen(_:)``, in order: an order test reads that the page
    /// hid before it froze and thawed before it showed.
    public private(set) var lifecycleSteps: [LifecycleStep] = []
    /// What ``setFrozen(_:)`` answers (false: the engine still counts the page visible).
    public var freezes = true

    /// What ``pushesToPage`` answers: true stands for a fork with the page push channel and the feature on.
    public var pushChannel = false
    /// Every ``push(_:)`` the page took, in order.
    public private(set) var pushes: [String] = []
    /// Runs after each push (tests wait on it).
    public var onPush: (() -> Void)?

    /// Makes a page with no calls yet.
    ///
    /// - Parameter usesRendererPaths: The page is on the fork's renderer paths.
    public init(usesRendererPaths: Bool = false) {
        self.usesRendererPaths = usesRendererPaths
    }

    /// Posts `message` on the page channel from the page's main frame, as the page host relay does:
    /// stamped with ``senderURL``, the URL of the document that sent it.
    ///
    /// - Parameter message: The page's text.
    public func post(_ message: String) {
        guard let sender = URL(string: senderURL) else { return }
        onEvent?(.pageHostPost(message, sender: sender))
    }

    /// ``pushChannel``.
    public var pushesToPage: Bool { pushChannel }

    /// Records `text` in ``pushes`` while ``pushChannel``; makes no DevTools call.
    public func push(_ text: String) {
        guard pushChannel else { return }
        pushes.append(text)
        onPush?()
    }

    /// Records the size in ``surfaceCopies`` and answers ``surfaceCopy`` at once; makes no DevTools call.
    public func copySurface(maxPixelSize: CGSize, done: @escaping @MainActor (PageSurfaceCopy?) -> Void) {
        surfaceCopies.append(maxPixelSize)
        done(surfaceCopy)
    }

    /// Records `point` in ``clicks`` when ``nativeClicks`` is on, and answers it; makes no DevTools call.
    public func sendClick(at point: CGPoint) -> Bool {
        guard nativeClicks, !closed else { return false }
        clicks.append(point)
        return true
    }

    /// Records `point` in ``mouseMoves`` when ``nativeMoves`` is on, and answers it; makes no DevTools call.
    public func sendMouseMove(at point: CGPoint) -> Bool {
        guard nativeMoves, !closed else { return false }
        mouseMoves.append(point)
        return true
    }

    /// Counts in ``selectionCopies``; makes no DevTools call.
    public func copySelection() { selectionCopies += 1 }

    /// Records `script` in ``evaluations`` and answers it through ``rendererEvaluate`` (`null` on renderer
    /// paths without one), or through the DevTools path (``PageChromiumPage/devToolsEvaluate(_:)``).
    public func evaluate(_ script: String) async throws -> Any? {
        evaluations.append(script)
        defer { onEvaluate?() }
        if let evaluateGate { await evaluateGate() }
        let renderer: ((String) throws -> String)? = rendererEvaluate ?? (usesRendererPaths ? { _ in "null" } : nil)
        guard let renderer else { return try await devToolsEvaluate(script) }
        let text = try renderer(script)
        guard !text.isEmpty else { return nil }
        guard let value = try? JSONSerialization.blockingJSONObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw PageScriptError.noResult
        }
        return value
    }

    /// Records the call and answers it: ``answer`` first, then ``devToolsFailure``, then the sender
    /// check, then an empty result.
    public func devTools(_ method: String, params: [String: any Sendable]) async throws -> String {
        calls.append((method, params))
        defer { onCall?() }
        let answered = answer?(method, params)
        if let devToolsFailure { throw devToolsFailure }
        if let answered { return answered }
        if method == "Runtime.evaluate", params["expression"] as? String == "[location.href, window === window.top]" {
            return #"{"result":{"type":"object","value":["\#(senderURL)",\#(senderIsTop)]}}"#
        }
        return #"{"result":{}}"#
    }

    /// Whether `window` is ``pageWindow``.
    public func isPageWindow(_ window: NSWindow) -> Bool { window === pageWindow }

    /// Records `url` in ``loaded`` and ends a discard.
    public func load(_ url: URL) {
        isDiscarded = false
        if loaded.isEmpty { seeThroughAtFirstLoad = .some(seeThrough) }
        loaded.append(url)
    }

    /// Records the value in ``seeThrough``.
    public func setSeeThrough(_ seeThrough: Bool) { self.seeThrough = seeThrough }
    /// Counts in ``reloads`` and ends a discard (the reload brings the page back).
    public func reload() {
        reloads += 1
        isDiscarded = false
    }
    /// Records the value in ``zoom``.
    public func setZoom(_ zoom: Double) { self.zoom = zoom }
    /// Does nothing.
    public func setFocused(_ focused: Bool) {}
    /// Records `.visible(visible)` in ``lifecycleSteps``.
    public func setVisible(_ visible: Bool) { lifecycleSteps.append(.visible(visible)) }

    /// Records the move (``moves``).
    public func moveWindow(to window: PageChromiumWindow) { moves.append(window) }

    /// Records `.frozen(frozen)` in ``lifecycleSteps`` and answers ``freezes``; a closed page
    /// records nothing and answers false, as a CEF page does.
    @discardableResult
    public func setFrozen(_ frozen: Bool) -> Bool {
        guard !closed else { return false }
        lifecycleSteps.append(.frozen(frozen))
        return freezes
    }

    /// Answers ``discardAnswer``; a discard that took counts in ``discards`` and sets ``isDiscarded``.
    public func discard() -> Bool {
        guard discardAnswer, !closed else { return false }
        discards += 1
        isDiscarded = true
        return true
    }

    /// Every ``answerUnresponsive(terminate:)``, in order (true: terminate).
    public private(set) var hangAnswers: [Bool] = []

    /// Records `terminate` in ``hangAnswers``; a closed page records nothing.
    public func answerUnresponsive(terminate: Bool) {
        guard !closed else { return }
        hangAnswers.append(terminate)
    }

    /// Sets ``closed`` and runs ``onClose``.
    public func close() {
        closed = true
        onClose?()
    }
}
