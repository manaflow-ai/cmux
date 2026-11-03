package import WebKit

/// A script in a WebKit page without a user gesture (`BrowserScriptGesture.cmux`). Every public
/// WKWebView evaluation (`evaluateJavaScript`, `callAsyncJavaScript`) runs with a forced user
/// gesture, which gives the page the person's activation, in any content world (activation belongs
/// to the document). WebKit's SPI takes the gesture as a flag; which macOS has which was probed on
/// the fleet (system WebKit, `instancesRespond(to:)`, 2026-10-24):
///
/// | Path | Selector | 14.8 | 15.7 | 26.6 | 27 |
/// |---|---|---|---|---|---|
/// | ``Path/contentWorld`` | `_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:` | no | yes | yes | yes |
/// | ``Path/asyncFunction`` | `_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:` | yes | yes | yes | yes |
/// | ``Path/pageWorld`` | `_evaluateJavaScriptWithoutUserGesture:completionHandler:` (page world only) | yes | yes | yes | yes |
///
/// The first one the web view answers is used. With none the call throws
/// `BrowserTabError.unsupported` rather than run with a gesture (a probe then counts as
/// unanswered, and the page stays awake: the safe side).
@MainActor
package struct WebKitGestureFreeEvaluation {
    /// One gesture-free way to run a script.
    package enum Path: Equatable, Sendable {
        case contentWorld
        case asyncFunction
        case pageWorld
    }

    let webView: WKWebView
    /// Which selectors may be used (a seam: a test leaves out some to choose a path, as on an older
    /// macOS). A selector is used only when the web view also answers it, so the seam can only remove
    /// paths, never send an unanswered selector.
    let allows: (Selector) -> Bool

    package init(webView: WKWebView, allows: @escaping (Selector) -> Bool = { _ in true }) {
        self.webView = webView
        self.allows = allows
    }

    private func responds(_ selector: Selector) -> Bool {
        allows(selector) && webView.responds(to: selector)
    }

    // crash-allow: a string selector traps only when sent unanswered; `path` checks responds(to:) before any send, and with no path the call throws .unsupported.
    static let contentWorldSelector = NSSelectorFromString("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:")
    // crash-allow: as above.
    static let asyncFunctionSelector = NSSelectorFromString("_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:")
    // crash-allow: as above.
    static let pageWorldSelector = NSSelectorFromString("_evaluateJavaScriptWithoutUserGesture:completionHandler:")

    private typealias Completion = @convention(block) (Any?, (any Error)?) -> Void
    private typealias ContentWorldSend = @convention(c) (AnyObject, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, Bool, @escaping Completion) -> Void
    private typealias AsyncFunctionSend = @convention(c) (
        AnyObject, Selector, NSString, Bool, NSURL?, NSDictionary?, Bool, WKFrameInfo?, WKContentWorld, @escaping Completion
    ) -> Void
    private typealias PageWorldSend = @convention(c) (AnyObject, Selector, NSString, @escaping Completion) -> Void

    /// The path a plain script in `world` takes, nil when none can run it without a gesture.
    package func path(in world: WKContentWorld) -> Path? {
        if responds(Self.contentWorldSelector) { return .contentWorld }
        if responds(Self.asyncFunctionSelector) { return .asyncFunction }
        if world == .page, responds(Self.pageWorldSelector) { return .pageWorld }
        return nil
    }

    /// The path a function body with arguments takes: only ``Path/asyncFunction`` takes arguments.
    package func functionPath() -> Path? {
        responds(Self.asyncFunctionSelector) ? .asyncFunction : nil
    }

    /// The script's completion value (main frame), as `WebKitTab.evaluate` returns it.
    package func evaluate(_ script: String, in world: WKContentWorld) async throws -> BrowserJSValue {
        switch path(in: world) {
        case .contentWorld?:
            let send = unsafeBitCast(webView.method(for: Self.contentWorldSelector), to: ContentWorldSend.self)
            return try await answer { send(webView, Self.contentWorldSelector, script as NSString, nil, nil, world, false, $0) }
        case .asyncFunction?:
            let send = unsafeBitCast(webView.method(for: Self.asyncFunctionSelector), to: AsyncFunctionSend.self)
            return try await answer { send(webView, Self.asyncFunctionSelector, script as NSString, false, nil, nil, false, nil, world, $0) }
        case .pageWorld?:
            let send = unsafeBitCast(webView.method(for: Self.pageWorldSelector), to: PageWorldSend.self)
            return try await answer { send(webView, Self.pageWorldSelector, script as NSString, $0) }
        case nil:
            throw BrowserTabError.unsupported("evaluation without a user gesture")
        }
    }

    /// `body` run as an async function with named `arguments` (main frame), what it resolves to.
    package func callAsync(_ body: String, arguments: [String: Any], in world: WKContentWorld) async throws -> BrowserJSValue {
        guard functionPath() == .asyncFunction else { throw BrowserTabError.unsupported("a function call without a user gesture") }
        let send = unsafeBitCast(webView.method(for: Self.asyncFunctionSelector), to: AsyncFunctionSend.self)
        return try await answer {
            send(webView, Self.asyncFunctionSelector, body as NSString, true, nil, arguments as NSDictionary, false, nil, world, $0)
        }
    }

    /// Fire and forget: a script whose answer nobody reads (a clear, an exit); an engine without a
    /// gesture-free path runs nothing.
    package func run(_ script: String, in world: WKContentWorld) {
        Task { _ = try? await evaluate(script, in: world) }
    }

    private func answer(_ send: (@escaping Completion) -> Void) async throws -> BrowserJSValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserJSValue, any Error>) in
            send { value, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: BrowserJSValue(foundation: value)) }
            }
        }
    }
}
