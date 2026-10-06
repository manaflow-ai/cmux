public import WebKit

/// A frame's document as the domain policy judges it: `location.origin`
/// and `location.protocol + "//" + location.host`. `location` and its
/// members are unforgeable, so script in any content world reads WebKit's
/// own values there.
public struct BrowserReplFrameDocument: Sendable, Equatable {
    /// The document's origin (`location.origin`, `"null"` when opaque).
    public var origin: String?
    /// The document URL's scheme and host: `https://example.com:8443`, `about://`.
    public var place: String
    /// Who made an opaque document (``isOpaque``), as the navigation
    /// delegate recorded it (``BrowserReplDocumentProvenance``); nil when
    /// nothing was recorded. Not part of equality: it describes the frame's
    /// history, not the document.
    public var makers: [BrowserReplDocumentMaker]?
    /// For a local document (a `file:` URL, or a document of a local file's
    /// origin under another URL), its URL without the fragment: every local
    /// file has the same origin and place, so only this tells two of them
    /// apart. Nil for any other document.
    public var local: String?
    /// For an opaque document (``isOpaque``), its URL without the fragment.
    /// Two opaque documents have the same origin and place, and a frame's
    /// makers can grow between the gate's check and its script reaching the
    /// frame, so a gated script runs only in the opaque document whose URL
    /// the gate approved. A `data:` URL holds the document's content and a
    /// `blob:` URL is unique; an `about:srcdoc` or sandboxed `about:blank`
    /// URL tells nothing. Nil for any other document, and not part of
    /// equality: WebKit's record and the document can spell one URL
    /// differently.
    public var opaque: String?

    public init(origin: String?, place: String, makers: [BrowserReplDocumentMaker]? = nil, local: String? = nil, opaque: String? = nil) {
        self.origin = origin
        self.place = place
        self.makers = makers
        self.local = local
        self.opaque = opaque
    }

    /// `url` without its fragment.
    static func withoutFragment(_ url: URL?) -> String {
        let text = url?.absoluteString ?? ""
        return text.firstIndex(of: "#").map { String(text[..<$0]) } ?? text
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.origin == rhs.origin && lhs.place == rhs.place && lhs.local == rhs.local
    }

    /// `url` without its fragment when the document is local (its origin
    /// is a local file's, or `url` is a `file:` URL), else nil.
    static func local(url: URL?, origin: String?) -> String? {
        guard origin?.lowercased() == "file://" || url?.scheme?.lowercased() == "file" else { return nil }
        return withoutFragment(url)
    }

    /// Whether the document has an opaque origin and a URL that names no
    /// host (`data:`, `about:`, `blob:`): neither tells who wrote it.
    public var isOpaque: Bool {
        (origin == nil || origin == "null") && Self.hostlessPlaces.contains(place)
    }

    static let hostlessPlaces: Set<String> = ["about://", "data://", "blob://"]

    /// The addresses a judge must allow, each as `scheme://host[:port]`:
    /// the document's origin (unless opaque) and its URL's place (unless
    /// the URL names no host). Both are judged, never one alone: a page can
    /// relax `document.domain` to a parent domain, and the URL's host still
    /// names the page that wrote the document. An ``isOpaque`` document has
    /// none; it is judged by its makers instead.
    public var judgedAddresses: [String] {
        var addresses: [String] = []
        if let origin, origin != "null" { addresses.append(origin) }
        if !Self.hostlessPlaces.contains(place) { addresses.append(place) }
        return addresses
    }

    /// Whether a secret scoped to `domains` may go into this document: it
    /// has an origin, and its origin and URL place (``judgedAddresses``)
    /// are each on one of `domains` (secret semantics,
    /// ``BrowserReplDomainPattern/matches(origin:secure:)``).
    public func isOn(secretDomains domains: [BrowserReplDomainPattern]) -> Bool {
        guard let origin, origin != "null", !isOpaque else { return false }
        return judgedAddresses.allSatisfy { address in domains.contains { $0.matches(origin: address, secure: true) } }
    }

    /// The document WebKit recorded for a frame when the tree was read; a
    /// frame that navigated since shows another one.
    @MainActor
    public init(info: WKFrameInfo) {
        origin = Self.origin(of: info.securityOrigin)
        place = Self.place(of: info.request.url)
        local = Self.local(url: info.request.url, origin: origin)
        if isOpaque {
            makers = BrowserReplDocumentProvenance.makers(of: info)
            opaque = info.request.url.map { Self.withoutFragment($0) }
        }
    }

    /// This document with the makers recorded for `frame` of `webView`
    /// (`nil`: the main frame) when it is opaque.
    @MainActor
    func withMakers(frame: WKFrameInfo?, in webView: WKWebView) -> Self {
        guard isOpaque else { return self }
        var document = self
        let key = frame.flatMap(BrowserReplDocumentProvenance.frameKey) ?? (frame == nil ? "main" : nil)
        document.makers = key.flatMap { BrowserReplDocumentProvenance.makers(ofFrame: $0, in: webView) }
        return document
    }

    /// `scheme://host[:port]` of a WebKit security origin, `"null"` when opaque.
    @MainActor
    static func origin(of securityOrigin: WKSecurityOrigin) -> String {
        guard !securityOrigin.protocol.isEmpty else { return "null" }
        let scheme = securityOrigin.protocol.lowercased()
        let port = securityOrigin.port
        let isDefault = port == 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(bracketed(securityOrigin.host.lowercased()))" + (isDefault ? "" : ":\(port)")
    }

    /// A main frame's document as its URL names it.
    public init(url: URL?) {
        place = Self.place(of: url)
        let scheme = url?.scheme?.lowercased()
        origin = scheme == "http" || scheme == "https" ? place : nil
        local = Self.local(url: url, origin: origin)
        if isOpaque, let url { opaque = Self.withoutFragment(url) }
    }

    private static func place(of url: URL?) -> String {
        // A frame with no URL shows its initial empty document.
        guard let url, let scheme = url.scheme?.lowercased() else { return "about://" }
        var host = bracketed((url.host(percentEncoded: true) ?? "").lowercased())
        if let port = url.port,
           !((scheme == "https" || scheme == "wss") && port == 443),
           !((scheme == "http" || scheme == "ws") && port == 80) {
            host += ":\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func bracketed(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}

extension WKWebView {
    private static let callWithGestureSelector = NSSelectorFromString("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:")

    /// `callAsyncJavaScript`, with or without a user gesture. WebKit's public
    /// call always gives the script one (a page may then write the system
    /// clipboard); without one this uses WebKit's own variant that takes the
    /// choice, and throws `unsupported` when that is missing rather than
    /// give the gesture anyway.
    @MainActor
    public func browserReplCallAsyncJavaScript(
        _ body: String,
        arguments: [String: Any],
        in frame: WKFrameInfo?,
        contentWorld: WKContentWorld,
        userGesture: Bool
    ) async throws -> Any? {
        if userGesture {
            return try await callAsyncJavaScript(body, arguments: arguments, in: frame, contentWorld: contentWorld)
        }
        guard responds(to: Self.callWithGestureSelector) else {
            throw BrowserReplDriverError(code: "unsupported", message: "This WebKit cannot run the agent's script without a user gesture")
        }
        typealias Completion = @convention(block) (Any?, (any Error)?) -> Void
        typealias Function = @convention(c) (AnyObject, Selector, NSString, NSDictionary, WKFrameInfo?, WKContentWorld, Bool, Completion) -> Void
        let function = unsafeBitCast(method(for: Self.callWithGestureSelector), to: Function.self)
        let box = BrowserReplScriptResultBox()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserReplScriptResult, any Error>) in
            box.continuation = continuation
            let completion: Completion = { value, error in
                MainActor.assumeIsolated {
                    if let error { box.finish(.failure(error)) } else { box.finish(.success(BrowserReplScriptResult(value: value))) }
                }
            }
            function(self, Self.callWithGestureSelector, body as NSString, arguments as NSDictionary, frame, contentWorld, false, completion)
        }
        return result.value is NSNull ? nil : result.value
    }
}

extension WKWebView {
    private static let evaluateWithGestureSelector = NSSelectorFromString("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:")

    /// `evaluateJavaScript(_:in:contentWorld:)` without a user gesture
    /// (WebKit's public call always gives one); throws `unsupported` when
    /// WebKit's variant that takes the choice is missing.
    @MainActor
    public func browserReplEvaluateJavaScriptWithoutGesture(
        _ source: String,
        in frame: WKFrameInfo?,
        contentWorld: WKContentWorld
    ) async throws -> Any? {
        guard responds(to: Self.evaluateWithGestureSelector) else {
            throw BrowserReplDriverError(code: "unsupported", message: "This WebKit cannot run the driver's script without a user gesture")
        }
        typealias Completion = @convention(block) (Any?, (any Error)?) -> Void
        typealias Function = @convention(c) (AnyObject, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, Bool, Completion) -> Void
        let function = unsafeBitCast(method(for: Self.evaluateWithGestureSelector), to: Function.self)
        let box = BrowserReplScriptResultBox()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrowserReplScriptResult, any Error>) in
            box.continuation = continuation
            let completion: Completion = { value, error in
                MainActor.assumeIsolated {
                    if let error { box.finish(.failure(error)) } else { box.finish(.success(BrowserReplScriptResult(value: value))) }
                }
            }
            function(self, Self.evaluateWithGestureSelector, source as NSString, nil, frame, contentWorld, false, completion)
        }
        return result.value is NSNull ? nil : result.value
    }
}

/// A script's result, handed from WebKit's completion on the main thread.
private struct BrowserReplScriptResult: @unchecked Sendable {
    let value: Any?
}

/// Resumes a script call's continuation once.
@MainActor
private final class BrowserReplScriptResultBox {
    var continuation: CheckedContinuation<BrowserReplScriptResult, any Error>?

    func finish(_ result: Result<BrowserReplScriptResult, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension WKNavigationAction {
    /// The document of the frame that started the navigation, as WebKit
    /// recorded it, or nil when no frame did (a load the app started).
    /// `sourceFrame` is declared non-null but WebKit leaves it nil for such
    /// loads, so it is read without Swift's non-null assumption.
    @MainActor
    public var browserReplSourceDocument: BrowserReplFrameDocument? {
        (value(forKey: "sourceFrame") as? WKFrameInfo).map(BrowserReplFrameDocument.init(info:))
    }
}

extension BrowserReplDomainPolicy {
    /// Why the policy blocks a frame that shows `document`, or nil. Its
    /// origin and its URL's host (``BrowserReplFrameDocument/judgedAddresses``)
    /// must both be allowed, so a page that relaxed `document.domain` onto
    /// an allowed parent domain stays blocked: an `about:blank` or
    /// `blob:` document carries the origin of the page that made it, and is
    /// judged by that origin alone (its URL names no host).
    ///
    /// An opaque document (``BrowserReplFrameDocument/isOpaque``: a `data:`
    /// document, a sandboxed `about:srcdoc`, a `blob:` of an opaque origin)
    /// has neither, so it is judged by the documents that made it
    /// (``BrowserReplDocumentProvenance``): blocked when the policy blocks
    /// one of them, and, under a locked policy, when cmux cannot tell who
    /// made it. A page the policy blocks could otherwise show its content in
    /// a `data:` document of its own frame.
    public func blockReason(document: BrowserReplFrameDocument) -> String? {
        guard isActive else { return nil }
        if document.isOpaque { return opaqueBlockReason(document) }
        for address in document.judgedAddresses {
            if let reason = blockReason(address + "/") { return reason }
        }
        return nil
    }

    private func opaqueBlockReason(_ document: BrowserReplFrameDocument) -> String? {
        var unknown = document.makers?.isEmpty ?? true
        for maker in document.makers ?? [] {
            switch maker {
            case .app:
                continue
            case .page(let page):
                if let reason = blockReason(document: page) {
                    let shown = page.origin.flatMap { $0 == "null" ? nil : $0 } ?? page.place
                    return "a \(document.place.dropLast(3)): document made by \(shown), which the domain policy blocks: \(reason)"
                }
            case .unknown:
                unknown = true
            }
        }
        guard unknown, locked else { return nil }
        return "a \(document.place.dropLast(3)): document of an opaque origin whose maker cmux cannot tell, which a locked domain policy refuses; navigate the frame to an allowed page"
    }
}

/// Applies a REPL session's domain policy to every frame of a tab, not only
/// its main frame: a page the policy allows can embed a frame that shows a
/// page it blocks (a tab the user owns has no content rules, and a frame can
/// load before the policy is set).
///
/// Decisions come from WebKit's record of each frame (`WKFrameInfo`) and from
/// the frame's document read in the gate's content world, which agent and
/// page code cannot reach; never from anything the REPL's JavaScript sends.
/// A frame keeps its id when it navigates, so an evaluation is bound to the
/// document the gate approved: it checks `location` first and runs nothing
/// in another document.
@MainActor
public final class BrowserReplFrameGate {
    /// The session's policy; only the native session sets it.
    public var policy = BrowserReplDomainPolicy()
    /// Whom the gate judges for in one web view: the session, its
    /// directories and the tab as the authority sees it.
    public struct Scope: Sendable, Equatable {
        /// The session the gate serves.
        public var sessionID: String
        /// The session's working and temporary directories (canonical), the
        /// only ones a tab it did not create may show local files from;
        /// nil when not known, and then local files are not judged.
        public var fileRoots: [String]?
        /// The tab that shows the web view (its creator, main-frame URL,
        /// attached sessions), as ``BrowserReplDocumentAuthority`` judges it.
        public var tab: BrowserReplTabFacts
        /// The session's workspace; with the tab's workspace in ``tab``,
        /// the gate refuses a tab that moved out of it
        /// (``checkTab(in:)``). Nil judges no workspace.
        public var workspaceID: UUID?

        public init(sessionID: String, fileRoots: [String]?, tab: BrowserReplTabFacts, workspaceID: UUID? = nil) {
            self.sessionID = sessionID
            self.fileRoots = fileRoots
            self.tab = tab
            self.workspaceID = workspaceID
        }
    }

    /// The scope of `webView`, from the real tab facts; set by the driver.
    /// In a tab the session did not create whose main frame does not show
    /// a web page, a frame that shows a local document outside the
    /// session's directories (a file outside them, or a document of a local
    /// file's origin under another URL, whose file cannot be told) is judged
    /// like a frame the policy blocks, whatever the policy
    /// (``BrowserReplDocumentAuthority/judgesLocalDocuments(in:)``). Without
    /// a scope (a gate made for one check of a session's own tab) the gate
    /// judges by ``policy`` alone, in no tab.
    public var scope: @MainActor (WKWebView) -> Scope? = { _ in nil }

    /// Reads `webView`'s frame tree as it is now; the driver shares one
    /// read among its callers (``callAsyncJavaScript(_:arguments:in:frame:contentWorld:userGesture:)``
    /// judges every frame a script could reach).
    public var frameTree: @MainActor (WKWebView) async -> [BrowserReplFrame] = { await BrowserReplFrame.readTree(of: $0) }

    /// The authority that judges `webView`'s documents, and the tab as it
    /// needs it: the gate's policy, with the session, its directories and
    /// the tab from ``scope``. The gate decides nothing itself.
    private func authority(in webView: WKWebView) -> (BrowserReplDocumentAuthority, BrowserReplTabFacts?) {
        guard let scope = scope(webView) else { return (.judging(policy), nil) }
        return (BrowserReplDocumentAuthority(sessionID: scope.sessionID, policy: policy, fileRoots: scope.fileRoots, workspaceID: scope.workspaceID), scope.tab)
    }

    /// Throws `denied` when the session may no longer use the tab that
    /// shows `webView` (``BrowserReplTabCapability/use``), judged with the
    /// tab as ``scope`` reads it now: a call that started on a tab of the
    /// session's workspace and was suspended in WebKit while the user moved
    /// the tab to another one reads and sends nothing more. Every script
    /// the gate runs and every input it guards asks it first, and the
    /// driver asks it before each native input event.
    ///
    /// A call that was cancelled (its cell timed out, its session was
    /// reset or closed) is refused too (`cancelled`), so it reads and sends
    /// nothing more after a suspension in WebKit.
    ///
    /// While guarded input is in flight in `webView`
    /// (``guardingInput(in:frames:checkFocusAfter:_:)``) it also judges the
    /// main frame's live page: the input sends several native events (a
    /// drag's press, moves and release) and the page can navigate its main
    /// frame between two of them, which the child-frame hold does not stop.
    /// A page the authority refuses fails with its refusal (`blocked`), and
    /// a main frame of another origin than when the input started with
    /// `stale`: the input's frame checks and guards judged the old document
    /// only. WebKit names a main-frame navigation's page from its start,
    /// before it commits.
    public func checkTab(in webView: WKWebView) throws {
        if Task.isCancelled {
            throw BrowserReplDriverError(code: "cancelled", message: "cancelled because the cell that made the call timed out or its session ended; nothing more was sent to the tab")
        }
        let (authority, tab) = authority(in: webView)
        if let tab, let refusal = authority.verdict(BrowserReplAccess(in: tab, capability: .use)).refusal {
            throw BrowserReplDriverError(code: refusal.code, message: refusal.message)
        }
        guard let started = inputMainFrames[ObjectIdentifier(webView)], !started.isEmpty else { return }
        let live = webView.url
        try authority.verdict(BrowserReplAccess(.tabPage(live?.absoluteString ?? ""), in: tab)).check()
        let origin = Self.mainFrameOrigin(live)
        if started.values.contains(where: { $0 != origin }) {
            throw BrowserReplDriverError(
                code: "stale",
                message: "the tab's main frame navigated to \(origin.isEmpty ? "another page" : origin) while the input was in flight, so nothing more was sent (the drag ended with no drop); run the input again on the new page"
            )
        }
    }

    /// The main frame's origin as ``checkTab(in:)`` compares it during
    /// input: scheme, host and port, or the whole URL for one without a
    /// host (`about:blank`, `data:`), which may be a document of another
    /// origin.
    private static func mainFrameOrigin(_ url: URL?) -> String {
        guard let url else { return "" }
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        let scheme = url.scheme?.lowercased() ?? ""
        return "\(scheme)://\(host.lowercased())" + (url.port.map { ":\($0)" } ?? "")
    }

    /// Whether the gate judges `webView`'s frames: a domain policy is in
    /// force, or its local documents are judged (``scope``).
    public func isActive(in webView: WKWebView) -> Bool {
        let (authority, tab) = authority(in: webView)
        return authority.isActive(in: tab)
    }

    /// Why a frame of `webView` that shows `document` is refused
    /// (``BrowserReplDocumentAuthority/verdict(_:)``): the policy blocks it,
    /// or it is a local document the session may not read.
    public func blockReason(_ document: BrowserReplFrameDocument, in webView: WKWebView) -> String? {
        let (authority, tab) = authority(in: webView)
        return authority.verdict(BrowserReplAccess(.document(document), in: tab)).reason
    }

    /// Why a session whose directories are `roots` may not read `document`
    /// in a tab it did not create, or nil: a local file outside `roots`, a
    /// document of a local file's origin under another URL, or an opaque
    /// document (``BrowserReplFrameDocument/isOpaque``) that such a document
    /// made, or whose maker cmux cannot tell. A file can replace itself with
    /// a `data:` document that shows its content, whose origin and URL name
    /// no file, so an opaque document is judged by its makers
    /// (``BrowserReplDocumentProvenance``, which passes an opaque maker's
    /// own makers on).
    nonisolated public static func localBlockReason(_ document: BrowserReplFrameDocument, roots: [String]) -> String? {
        if let local = document.local {
            return BrowserReplFileSandbox.localPageRefusal(url: local, documentOrigin: document.origin, roots: roots)
        }
        guard document.isOpaque else { return nil }
        let kind = "a \(document.place.dropLast(3)): document"
        guard let makers = document.makers, !makers.isEmpty else {
            return "\(kind) of an opaque origin whose maker cmux cannot tell, which may be a local file the session may not read; navigate the frame to another page"
        }
        for maker in makers {
            switch maker {
            case .app:
                continue
            case .unknown:
                return "\(kind) of an opaque origin whose maker cmux cannot tell, which may be a local file the session may not read; navigate the frame to another page"
            case .page(let page):
                if let reason = localBlockReason(page, roots: roots) {
                    return "\(kind) made by \(page.local ?? page.place): \(reason)"
                }
            }
        }
        return nil
    }
    let world: WKContentWorld
    /// Bounds each of the gate's own probes (a frame's document, its focus,
    /// the frame boxes); one that does not answer in time refuses the call
    /// with `stale`.
    private let prober: BrowserReplScriptProbe
    /// The document each frame last showed when the gate read it.
    private var known: [Key: BrowserReplFrameDocument] = [:]
    /// The main frame's origin when each guarded input in flight started,
    /// by web view and input (``checkTab(in:)``).
    private var inputMainFrames: [ObjectIdentifier: [UUID: String]] = [:]
    /// Holds back child-frame loads while guarded input or a capture is in
    /// flight; the navigation delegate honors it.
    public let loadHold: BrowserReplSubframeLoadHold
    /// Test seam: runs after the blocked frames reported their positions
    /// and before their parents guard them, where page script can run in
    /// production.
    var inputPositionsRead: (@MainActor () async -> Void)?

    private struct Key: Hashable {
        let webView: ObjectIdentifier
        let frameID: String
    }

    /// - Parameters:
    ///   - world: a content world agent and page code cannot reach.
    ///   - probeTimeout: the bound on each of the gate's own probes.
    ///   - clock: measures `probeTimeout`.
    ///   - loadHold: the hold the web views' navigation delegate honors.
    public init(
        world: WKContentWorld,
        probeTimeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock(),
        loadHold: BrowserReplSubframeLoadHold = .shared
    ) {
        self.world = world
        self.loadHold = loadHold
        prober = BrowserReplScriptProbe(timeout: probeTimeout, clock: clock)
    }

    /// Why the policy blocks the document WebKit recorded for `frame` when
    /// the tree was read, or nil. The main frame without frame info is
    /// judged by the web view's URL.
    public func recordedBlockReason(of frame: BrowserReplFrame, in webView: WKWebView) -> String? {
        guard isActive(in: webView) else { return nil }
        if let info = frame.info { return blockReason(BrowserReplFrameDocument(info: info), in: webView) }
        return blockReason(BrowserReplFrameDocument(url: webView.url).withMakers(frame: nil, in: webView), in: webView)
    }

    /// Reads the document `frame` shows now and throws `blocked` when the
    /// policy blocks it. Returns the document, or nil without a policy.
    @discardableResult
    public func authorize(_ frame: BrowserReplFrame, in webView: WKWebView) async throws -> BrowserReplFrameDocument? {
        guard isActive(in: webView) else { return nil }
        let document = try await read(frame, in: webView)
        if let reason = blockReason(document, in: webView) {
            throw blocked(frame, document: document, reason: reason)
        }
        known[key(frame, webView)] = document
        return document
    }

    /// Runs `body` (a `callAsyncJavaScript` function body) in `frame` only
    /// while the frame shows a document the policy allows. The call first
    /// checks, in the frame, that the document is the one the gate approved,
    /// and returns without running `body` if the frame has navigated since;
    /// the gate then judges the new document and runs it again.
    ///
    /// The script runs without a user gesture unless `userGesture` is true
    /// (the agent's page-world script): a page's handler it sets off synchronously (a
    /// `focus`, a dispatched event) holds none either, and neither does code
    /// that replaced a getter the script reads in its world, so none of them
    /// can write the system clipboard or open a window.
    public func callAsyncJavaScript(
        _ body: String,
        arguments: [String: Any],
        in webView: WKWebView,
        frame: BrowserReplFrame,
        contentWorld: WKContentWorld,
        userGesture: Bool = false
    ) async throws -> Any? {
        try checkTab(in: webView)
        guard isActive(in: webView) else {
            let value = try await webView.browserReplCallAsyncJavaScript(body, arguments: arguments, in: frame.info, contentWorld: contentWorld, userGesture: userGesture)
            // The tab may have moved out of the session's workspace while
            // the script ran: its result is not handed on.
            try checkTab(in: webView)
            return value
        }
        let key = key(frame, webView)
        // An opaque document's origin and place do not tell it from the
        // next opaque document the frame shows (a frame keeps its id when
        // it navigates): so its makers are read again on every call, never
        // taken from the earlier verdict, and the document check below
        // also compares its URL. A frame's makers only grow, so a frame
        // that showed a blocked page's opaque document since is judged by
        // that page now; one that shows another opaque document when the
        // script arrives (its maker recorded after this check) runs
        // nothing there and is judged again.
        var expected = (known[key]
            ?? frame.info.map { BrowserReplFrameDocument(info: $0) }
            ?? BrowserReplFrameDocument(url: webView.url))
            .withMakers(frame: frame.info, in: webView)
        if blockReason(expected, in: webView) != nil, let current = try await authorize(frame, in: webView) {
            expected = current
        }
        // Script in a world agent or page code reaches can traverse to other
        // frames of the tab; a frame of its site that relaxes
        // `document.domain` becomes its origin. The gate's own world runs
        // only the driver's checks.
        let reaches = contentWorld != world
        if reaches { try await checkReach(from: expected, frame: frame, in: webView) }
        var bound = arguments
        for _ in 0..<3 {
            bound[Self.originArgument] = expected.origin ?? NSNull()
            bound[Self.placeArgument] = expected.place
            bound[Self.localArgument] = expected.local ?? NSNull()
            bound[Self.opaqueArgument] = expected.opaque ?? NSNull()
            let value = try await webView.browserReplCallAsyncJavaScript(
                Self.documentCheck + Self.scoped(body),
                arguments: bound,
                in: frame.info,
                contentWorld: contentWorld,
                userGesture: userGesture
            )
            guard value as? String == Self.movedMarker else {
                // An opaque document whose URL tells nothing (about:srcdoc,
                // a sandboxed about:blank) may have been made by a
                // navigation recorded while the script was on its way: its
                // result is not handed on when that maker is blocked.
                let after = expected.withMakers(frame: frame.info, in: webView)
                if let reason = blockReason(after, in: webView) {
                    known[key] = nil
                    throw blocked(frame, document: after, reason: reason)
                }
                // A blocked frame of the site that loaded while the script
                // ran: its result is not handed on.
                if reaches { try await checkReach(from: expected, frame: frame, in: webView) }
                // Nor from a tab that moved out of the session's workspace
                // (or whose call was cancelled) while the script ran.
                try checkTab(in: webView)
                known[key] = expected
                return value
            }
            guard let current = try await authorize(frame, in: webView) else { break }
            expected = current
        }
        throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) kept navigating; try again once it has loaded")
    }

    /// Throws `blocked` when a frame of the tab that the authority refuses
    /// shows a document that script in `frame`, which shows `document`,
    /// could reach: one whose host shares a domain with the target's that
    /// both could set `document.domain` to (a common suffix that is not a
    /// public suffix), which makes them one origin to page script. Hosts are
    /// compared whatever their scheme and port, which relaxation ignores.
    ///
    /// A tree read that lost frames could hide such a frame, so it fails
    /// closed (`stale`), as input and captures do.
    private func checkReach(from document: BrowserReplFrameDocument, frame: BrowserReplFrame, in webView: WKWebView) async throws {
        guard let host = Self.host(of: document) else { return }
        let frames = await frameTree(webView)
        try await requireWholeTree(frames, in: webView)
        for other in frames where other.frameID != frame.frameID {
            let recorded = other.info.map { BrowserReplFrameDocument(info: $0) } ?? BrowserReplFrameDocument(url: webView.url)
            guard let otherHost = Self.host(of: recorded), Self.canRelaxToOneOrigin(host, otherHost),
                  let reason = recordedBlockReason(of: other, in: webView) else { continue }
            throw BrowserReplDriverError(
                code: "blocked",
                message: "Frame \(frame.frameID) shares the site of frame \(other.frameID) (\(otherHost)), which page script there can reach by setting document.domain, and the domain policy blocks it: \(reason)"
            )
        }
    }

    private static func host(of document: BrowserReplFrameDocument) -> String? {
        guard let origin = document.origin, origin != "null", let host = URL(string: origin)?.host(percentEncoded: false),
              !host.isEmpty else { return nil }
        return host
    }

    /// Whether documents of hosts `a` and `b` can become one origin by
    /// setting `document.domain`: the same host, or a common domain suffix
    /// that is not a public suffix. Where the system's list cannot be read,
    /// any shared suffix counts (it refuses more, never less).
    nonisolated static func canRelaxToOneOrigin(_ a: String, _ b: String, publicSuffixes: BrowserReplPublicSuffixList = .system) -> Bool {
        let x = BrowserReplHostName.normalize(a)
        let y = BrowserReplHostName.normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        if BrowserReplHostName.isIPAddress(x) || BrowserReplHostName.isIPAddress(y) { return false }
        var common: [Substring] = []
        for (l, r) in zip(x.split(separator: ".").reversed(), y.split(separator: ".").reversed()) {
            guard l == r else { break }
            common.append(l)
        }
        guard !common.isEmpty else { return false }
        return !publicSuffixes.isPublicSuffix(common.reversed().joined(separator: "."))
    }

    /// Throws `blocked` when a pointer event at any of `points` (CSS pixels
    /// of the main frame's viewport) could reach a frame the policy blocks:
    /// the point is inside the box of the main frame's child frame that is,
    /// or holds, a blocked frame. Overlapping content is not subtracted, and
    /// a blocked frame whose box cannot be found refuses every point.
    public func checkPointer(at points: [CGPoint], in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        guard isActive(in: webView), !points.isEmpty else { return }
        try await requireWholeTree(frames, in: webView)
        let tops = try blockedTops(frames, in: webView)
        guard !tops.isEmpty else { return }
        let found = try await boxes(of: tops, in: webView, frames: frames, effects: false)
        for (entry, box) in zip(tops, found.boxes) {
            guard let box else {
                throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.blocked.url) shows a page the domain policy blocks (\(entry.reason)) and its position is unknown, so pointer input to this tab is refused")
            }
            for point in points where point.x >= box.minX && point.x <= box.maxX && point.y >= box.minY && point.y <= box.maxY {
                throw BrowserReplDriverError(code: "blocked", message: "The point (\(Self.format(point.x)), \(Self.format(point.y))) is over frame \(entry.blocked.url), which the domain policy blocks: \(entry.reason)")
            }
        }
    }

    /// Throws `blocked` when keyboard input would reach a frame the policy
    /// blocks: the frame holds the focus (its document has it, or holds a
    /// focused element, or its parent's focused element is its frame
    /// element). A frame that cannot answer counts as focused.
    public func checkFocus(in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        guard isActive(in: webView) else { return }
        try await requireWholeTree(frames, in: webView)
        let blockedFrames = blocked(frames, in: webView)
        guard !blockedFrames.isEmpty else { return }
        let byID = Dictionary(frames.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in blockedFrames {
            let refusal = BrowserReplDriverError(code: "blocked", message: "The keyboard focus is in frame \(entry.frame.url), which the domain policy blocks: \(entry.reason)")
            guard let info = entry.frame.info else { throw refusal }
            let focus: [String: Any]
            do {
                focus = try await probe(
                    Self.focusSource, arguments: [:], in: webView, frame: info,
                    what: "frame \(entry.frame.url) did not report its focus"
                ) as? [String: Any] ?? [:]
            } catch let error as BrowserReplDriverError where error.code == "stale" {
                throw error
            } catch {
                // A frame that has gone takes no input; any other failure
                // leaves its focus unknown.
                if Self.isGoneFrame(error) { continue }
                throw refusal
            }
            if focus["inner"] as? Bool == true { continue }
            if focus["focused"] as? Bool == true { throw refusal }
            guard let parentID = entry.frame.parentFrameID, let parent = byID[parentID] else { continue }
            // The frame's own position in its parent's window.frames, as it
            // reported it: WebKit's tree also holds frames in shadow trees,
            // so a tree index can name a sibling there.
            let position = (focus["position"] as? NSNumber)?.intValue ?? -1
            let length = (focus["length"] as? NSNumber)?.intValue ?? -1
            let ownsFocus: Bool?
            do {
                ownsFocus = try await probe(
                    Self.ownerFocusSource, arguments: ["index": position, "length": length], in: webView, frame: parent.info,
                    what: "frame \(parent.url) did not report its focus"
                ) as? Bool
            } catch let error as BrowserReplDriverError where error.code == "stale" {
                throw error
            } catch {
                ownsFocus = nil
            }
            if ownsFocus ?? true { throw refusal }
        }
    }

    /// Runs `input`, trusted input for the whole tab (a point, a drag, a
    /// key, inserted text), with every frame the policy blocks held out of
    /// its reach while it is in flight.
    ///
    /// The driver's checks run before the input (`checkPointer`,
    /// `checkFocus`), and the input is a point or a key for the whole tab:
    /// the page can move a blocked frame under the point, or the focus into
    /// it, between a check and the event. So before `input` (and the checks
    /// it runs) the gate makes the element of each blocked frame `inert` in
    /// its parent, from its own content world: an inert element is not hit
    /// tested and takes no focus, wherever the page moves it. A blocked frame
    /// in a shadow tree cannot be told from its siblings there, so every
    /// frame element in the parent's shadow trees is made inert. The gate
    /// watches each guarded element's `inert` attribute from its world and
    /// puts it back the moment the page takes it off (a mutation observer
    /// runs before the page's script returns control, so before WebKit
    /// handles another event). From before the frame tree is read until the
    /// guard comes off, no child frame loads a new document
    /// (``BrowserReplSubframeLoadHold``): a frame the page creates meanwhile
    /// shows its initial empty document, with its parent's origin, and an
    /// allowed frame cannot navigate to a blocked page. With
    /// `checkFocusAfter` the focus is checked again after `input`, while the
    /// guard is on. Then the guard comes off, and `input` fails with
    /// `blocked` when the page changed the `inert` attribute of a guarded
    /// element meanwhile: within one event handler the page can take the
    /// attribute off and move the focus into the frame before the observer
    /// runs, so the rest of that key event may have reached it.
    ///
    /// Throws `blocked` before `input` when a blocked frame's element cannot
    /// be found (a closed shadow root), and `stale` when a frame does not
    /// answer or the page changes its frames during the setup.
    public func guardingInput<T>(
        in webView: WKWebView,
        frames: @MainActor () async -> [BrowserReplFrame],
        checkFocusAfter: Bool,
        _ input: () async throws -> T
    ) async throws -> T {
        try checkTab(in: webView)
        guard isActive(in: webView) else { return try await input() }
        let key = ObjectIdentifier(webView)
        let token = UUID()
        inputMainFrames[key, default: [:]][token] = Self.mainFrameOrigin(webView.url)
        defer {
            inputMainFrames[key]?[token] = nil
            if inputMainFrames[key]?.isEmpty == true { inputMainFrames[key] = nil }
        }
        return try await loadHold.holding(webView) {
            let guards = try await installInputGuards(in: webView, frames: await frames())
            let value: T
            do {
                try checkTab(in: webView)
                value = try await input()
                if checkFocusAfter { try await checkFocus(in: webView, frames: await frames()) }
            } catch {
                if let tampered = await releaseInputGuards(guards, in: webView) { throw tampered }
                throw error
            }
            if let tampered = await releaseInputGuards(guards, in: webView) { throw tampered }
            return value
        }
    }

    private struct InputGuard {
        let parent: BrowserReplFrame
        let token: String
        let guarded: [BrowserReplFrame]
        /// Each guarded frame's place in the parent's `window.frames` when
        /// the guard went on (-1 in a shadow tree).
        let positions: [Int]
    }

    /// Makes the element of each blocked frame without a blocked ancestor
    /// inert in its parent; see ``guardingInput(in:frames:checkFocusAfter:_:)``.
    private func installInputGuards(in webView: WKWebView, frames: [BrowserReplFrame]) async throws -> [InputGuard] {
        try await requireWholeTree(frames, in: webView)
        let blockedFrames = blocked(frames, in: webView)
        guard !blockedFrames.isEmpty else { return [] }
        let blockedIDs = Set(blockedFrames.map(\.frame.frameID))
        let byID = Dictionary(frames.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        if let main = frames.first, let entry = blockedFrames.first(where: { $0.frame.frameID == main.frameID }) {
            throw blocked(entry.frame, document: nil, reason: entry.reason)
        }
        // Blocked frames inside a blocked frame are out of reach with it.
        let tops = blockedFrames.filter { entry in
            var parentID = entry.frame.parentFrameID
            while let id = parentID {
                if blockedIDs.contains(id) { return false }
                parentID = byID[id]?.parentFrameID
            }
            return true
        }
        var byParent: [String: [(frame: BrowserReplFrame, reason: String, position: Int, length: Int)]] = [:]
        var parentOrder: [String] = []
        for entry in tops {
            guard let parentID = entry.frame.parentFrameID, byID[parentID] != nil, let info = entry.frame.info else {
                throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.frame.url) shows a page the domain policy blocks (\(entry.reason)) and its place is unknown, so input to this tab is refused")
            }
            let answer: [String: Any]
            do {
                answer = try await probe(
                    Self.positionSource, arguments: [:], in: webView, frame: info,
                    what: "frame \(entry.frame.url) did not report its position"
                ) as? [String: Any] ?? [:]
            } catch let error as BrowserReplDriverError {
                throw error
            } catch {
                // A frame that has gone takes no input.
                if Self.isGoneFrame(error) { continue }
                throw BrowserReplDriverError(code: "stale", message: "Frame \(entry.frame.url) did not report its position: \(error.localizedDescription)")
            }
            let position = (answer["position"] as? NSNumber)?.intValue ?? -1
            let length = (answer["length"] as? NSNumber)?.intValue ?? -1
            if byParent[parentID] == nil { parentOrder.append(parentID) }
            byParent[parentID, default: []].append((entry.frame, entry.reason, position, length))
        }
        await inputPositionsRead?()
        var installed: [InputGuard] = []
        do {
            for parentID in parentOrder {
                guard let parent = byID[parentID], let entries = byParent[parentID] else { continue }
                let token = UUID().uuidString
                let childCount = frames.filter { $0.parentFrameID == parentID }.count
                let value = try await probe(
                    Self.inputGuardSource,
                    arguments: [
                        "token": token,
                        "positions": entries.map(\.position).filter { $0 >= 0 },
                        "shadow": entries.contains { $0.position < 0 },
                        "length": entries.first?.length ?? -1,
                        "childCount": childCount,
                    ],
                    in: webView,
                    frame: parent.info,
                    what: "frame \(parent.url) did not guard its blocked frames"
                ) as? [String: Any] ?? [:]
                switch value["result"] as? String {
                case "ok":
                    installed.append(InputGuard(parent: parent, token: token, guarded: entries.map(\.frame), positions: entries.map(\.position)))
                case "changed":
                    throw BrowserReplDriverError(code: "stale", message: "The page changed its frames while input to frame \(parent.url) was prepared; try again")
                default:
                    let entry = entries[0]
                    throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.frame.url) shows a page the domain policy blocks (\(entry.reason)) and its frame element cannot be held out of the input's reach, so input to this tab is refused")
                }
            }
            try await verifyInputGuards(installed, in: webView)
        } catch {
            _ = await releaseInputGuards(installed, in: webView)
            throw error
        }
        return installed
    }

    /// Proves each guard holds the frame it is for. A position names
    /// whatever frame is at that place in `window.frames` when the parent
    /// runs its guard, and the page can reorder its frames after a blocked
    /// frame reported its place: the guard would then hold an allowed
    /// sibling and leave the blocked frame live. So each guarded frame
    /// reports its place again, by its own window (WebKit's handle of that
    /// frame), and its parent confirms that `window.frames` is the list it
    /// guarded, unchanged at every point between (a mutation observer the
    /// guard set compares it after each change of the document). Then the
    /// element made inert holds the blocked frame, and stays with it
    /// wherever the page moves it. Throws `stale` otherwise.
    private func verifyInputGuards(_ guards: [InputGuard], in webView: WKWebView) async throws {
        for entry in guards {
            for (frame, position) in zip(entry.guarded, entry.positions) {
                guard let info = frame.info else { continue }
                let answer: [String: Any]
                do {
                    answer = try await probe(
                        Self.positionSource, arguments: [:], in: webView, frame: info,
                        what: "frame \(frame.url) did not report its position"
                    ) as? [String: Any] ?? [:]
                } catch let error as BrowserReplDriverError {
                    throw error
                } catch {
                    // A frame that has gone takes no input.
                    if Self.isGoneFrame(error) { continue }
                    throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.url) did not report its position: \(error.localizedDescription)")
                }
                let now = (answer["position"] as? NSNumber)?.intValue ?? -1
                if now != position {
                    throw BrowserReplDriverError(code: "stale", message: "The page moved frame \(frame.url), which the domain policy blocks, while input to the tab was prepared; try again")
                }
            }
        }
        for entry in guards {
            let value = try await probe(
                Self.inputVerifySource, arguments: ["token": entry.token], in: webView, frame: entry.parent.info,
                what: "frame \(entry.parent.url) did not confirm its guard"
            ) as? [String: Any]
            if value?["result"] as? String != "ok" {
                throw BrowserReplDriverError(code: "stale", message: "The page changed its frames while input to frame \(entry.parent.url) was prepared; try again")
            }
        }
    }

    /// Takes the guards off. Returns `blocked` when the page changed a
    /// guarded element's `inert` attribute meanwhile, or the gate cannot
    /// tell (a parent that does not answer); a parent that has gone took its
    /// frames with it.
    private func releaseInputGuards(_ guards: [InputGuard], in webView: WKWebView) async -> BrowserReplDriverError? {
        var failure: BrowserReplDriverError?
        for entry in guards {
            let tampered: Bool
            do {
                let value = try await probe(
                    Self.inputReleaseSource, arguments: ["token": entry.token], in: webView, frame: entry.parent.info,
                    what: "frame \(entry.parent.url) did not release its blocked frames"
                ) as? [String: Any]
                tampered = value?["tampered"] as? Bool ?? true
            } catch {
                tampered = !Self.isGoneFrame(error)
            }
            if tampered, failure == nil {
                let urls = entry.guarded.map(\.url).joined(separator: ", ")
                failure = BrowserReplDriverError(code: "blocked", message: "The page took the guard off frame \(urls), which the domain policy blocks, while the input was in flight (or the guard could not be confirmed), so the input may have reached it")
            }
        }
        return failure
    }

    /// Throws `blocked` when any frame of the tab shows a page the policy
    /// blocks: a screenshot or PDF would show it.
    public func checkCapture(in webView: WKWebView, frames: [BrowserReplFrame]) throws {
        if isActive(in: webView), let unread = frames.first(where: \.childFramesUnread) {
            throw Self.incompleteTree(unread, documentCount: nil, treeCount: nil)
        }
        guard let entry = blocked(frames, in: webView).first else { return }
        throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(entry.frame.url), which the domain policy blocks: \(entry.reason); a capture would show it")
    }

    /// Runs `capture`, which returns an image of `region` (CSS pixels of the
    /// main frame's viewport, its origin at the image's top-left), and
    /// blanks in it the box of every main-frame child frame that is, or
    /// holds, a frame the policy blocks, as the tree is before and after
    /// the capture. A frame's content draws only inside its frame element's
    /// box, so the rest of the page stays as it is.
    ///
    /// The page can move a frame and put it back within the capture, so
    /// while it is taken each of those frame elements is also hidden
    /// (`visibility: hidden` and `transition-property: none`, both
    /// `!important` in its style attribute, which no style sheet, animation
    /// or transition outranks), from the gate's own world: a hidden frame
    /// draws nothing wherever it moves. The gate puts the style back the
    /// moment the page changes it (before the page's script returns, so
    /// before the next rendering), and the capture fails with `blocked` when
    /// the page changed it. From before the frame tree is read until after
    /// the capture, no child frame loads a new document
    /// (``BrowserReplSubframeLoadHold``), so a frame the page creates, or an
    /// allowed one it navigates, shows no blocked page meanwhile.
    ///
    /// Throws `blocked`, before or after the capture, when the main frame is
    /// blocked or a blocked frame's content cannot be hidden this way: its
    /// box is unknown, its frame element or an ancestor draws it elsewhere
    /// (`-webkit-box-reflect`, `filter`), or an element of the page samples
    /// what lies under it (`backdrop-filter`).
    ///
    /// - Parameter blockedChildFrames: Child frames (`frameID` to the
    ///   policy's reason) whose live document is blocked, as the capture
    ///   mask found them (``BrowserReplCaptureMask/BlockedChildFrames/handToCapture``):
    ///   a frame can navigate to a blocked page after the tree was read, so
    ///   its record still names the old one. They are blanked like the
    ///   blocked frames of the tree, and one missing from the tree read
    ///   before the capture refuses it.
    public func coverBlockedFrames(
        in webView: WKWebView,
        frames: @MainActor () async -> [BrowserReplFrame],
        blockedChildFrames: [String: String] = [:],
        capture: () async throws -> (image: CGImage, region: CGRect)
    ) async throws -> CGImage {
        guard isActive(in: webView) else { return try await capture().image }
        return try await loadHold.holding(webView) {
            let treeBefore = await frames()
            let before = try await captureCovers(in: webView, frames: treeBefore, alsoBlocked: blockedChildFrames, requireAlsoBlocked: true)
            let hidden = try await hideBlockedTops(in: webView, frames: treeBefore, alsoBlocked: blockedChildFrames)
            let image: CGImage
            let region: CGRect
            do {
                (image, region) = try await capture()
            } catch {
                _ = await unhide(hidden, in: webView)
                throw error
            }
            if let tampered = await unhide(hidden, in: webView) { throw tampered }
            let after = try await captureCovers(in: webView, frames: await frames(), alsoBlocked: blockedChildFrames, requireAlsoBlocked: false)
            let covers = before + after
            guard !covers.isEmpty else { return image }
            return try Self.blank(covers, in: image, region: region)
        }
    }

    /// A capture's hidden frame elements in the main frame, under `token`.
    struct HiddenFrames {
        let token: String
        let frames: [String]
    }

    /// Hides the element of each main-frame child frame that is, or holds,
    /// a blocked frame; see ``coverBlockedFrames(in:frames:blockedChildFrames:capture:)``.
    private func hideBlockedTops(
        in webView: WKWebView,
        frames: [BrowserReplFrame],
        alsoBlocked: [String: String]
    ) async throws -> HiddenFrames? {
        let tops = try blockedTops(frames, in: webView, alsoBlocked: alsoBlocked, requireAlsoBlocked: true)
        guard !tops.isEmpty else { return nil }
        let mainID = frames.first?.frameID
        let token = UUID().uuidString
        let value = try await probe(
            Self.hideSource,
            arguments: [
                "token": token,
                "indexes": tops.map(\.top.indexInParent),
                "childCount": frames.filter { $0.parentFrameID != nil && $0.parentFrameID == mainID }.count,
            ],
            in: webView,
            frame: nil,
            what: "the page did not hide its blocked frames"
        ) as? [String: Any] ?? [:]
        switch value["result"] as? String {
        case "ok":
            return HiddenFrames(token: token, frames: tops.map(\.blocked.url))
        case "changed":
            throw BrowserReplDriverError(code: "stale", message: "The page changed its frames while the capture was prepared; try again")
        default:
            throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(tops[0].blocked.url), which the domain policy blocks (\(tops[0].reason)), and its frame element cannot be hidden, so a capture could show it")
        }
    }

    /// Shows the hidden frame elements again. Returns `blocked` when the
    /// page changed their style meanwhile, or the gate cannot tell.
    private func unhide(_ hidden: HiddenFrames?, in webView: WKWebView) async -> BrowserReplDriverError? {
        guard let hidden else { return nil }
        let tampered: Bool
        do {
            let value = try await probe(
                Self.unhideSource, arguments: ["token": hidden.token], in: webView, frame: nil,
                what: "the page did not show its blocked frames again"
            ) as? [String: Any]
            tampered = value?["tampered"] as? Bool ?? true
        } catch {
            tampered = true
        }
        guard tampered else { return nil }
        return BrowserReplDriverError(
            code: "blocked",
            message: "The page changed the style of frame \(hidden.frames.joined(separator: ", ")), which the domain policy blocks, while the capture was taken (or it could not be confirmed hidden), so the capture was discarded"
        )
    }

    /// The boxes (CSS pixels of the main frame's viewport) a capture must
    /// blank; see ``coverBlockedFrames(in:frames:capture:)``.
    func captureCovers(
        in webView: WKWebView,
        frames: [BrowserReplFrame],
        alsoBlocked: [String: String] = [:],
        requireAlsoBlocked: Bool = false
    ) async throws -> [CGRect] {
        try await requireWholeTree(frames, in: webView)
        let tops = try blockedTops(frames, in: webView, alsoBlocked: alsoBlocked, requireAlsoBlocked: requireAlsoBlocked)
        guard !tops.isEmpty else { return [] }
        let found = try await boxes(of: tops, in: webView, frames: frames, effects: true)
        if found.backdrop {
            throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(tops[0].blocked.url), which the domain policy blocks (\(tops[0].reason)), and an element of the page blurs or filters what lies under it (backdrop-filter), so a capture could show the frame")
        }
        return try zip(tops, found.boxes).map { entry, box in
            guard let box else {
                throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(entry.blocked.url), which the domain policy blocks (\(entry.reason)); its position is unknown, so a capture could show it")
            }
            if found.escapes.contains(entry.top.frameID) {
                throw BrowserReplDriverError(code: "blocked", message: "The tab shows frame \(entry.blocked.url), which the domain policy blocks (\(entry.reason)), and the page draws it outside its box (-webkit-box-reflect or filter), so a capture could show it")
            }
            return box
        }
    }

    /// `image` (of `region`) with `covers` filled in gray.
    static func blank(_ covers: [CGRect], in image: CGImage, region: CGRect) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard region.width > 0, region.height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw BrowserReplDriverError(code: "invalid", message: "Could not hide the blocked frames in the capture")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scaleX = CGFloat(width) / region.width
        let scaleY = CGFloat(height) / region.height
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        for cover in covers {
            // Whole pixels, rounded outward, so no edge of the frame shows.
            let x = floor((cover.minX - region.minX) * scaleX)
            let top = floor((cover.minY - region.minY) * scaleY)
            let right = ceil((cover.maxX - region.minX) * scaleX)
            let bottom = ceil((cover.maxY - region.minY) * scaleY)
            context.fill(CGRect(x: x, y: CGFloat(height) - bottom, width: right - x, height: bottom - top))
        }
        guard let result = context.makeImage() else {
            throw BrowserReplDriverError(code: "invalid", message: "Could not hide the blocked frames in the capture")
        }
        return result
    }

    /// Throws `blocked` when the policy blocks the frame a file chooser
    /// opened from: as WebKit recorded it when the chooser opened, and the
    /// document it shows now. Throws `stale` when `frames` no longer has
    /// that frame (it went away, or its id could not be read): the document
    /// it shows cannot be judged, so the chooser may only be cancelled.
    /// Other frames of the tab do not matter; the files go only to that
    /// frame's input.
    public func checkFileChooser(frame info: WKFrameInfo, in webView: WKWebView, frames: [BrowserReplFrame]) async throws {
        let frame: BrowserReplFrame?
        if info.isMainFrame {
            frame = frames.first
        } else {
            let id = BrowserReplFrame.frameID(of: info)
            frame = id.flatMap { id in frames.first { $0.frameID == id } }
        }
        guard let frame else {
            throw BrowserReplDriverError(code: "stale", message: "The frame the file chooser opened in is gone or cannot be read, so the document it shows cannot be checked against the domain policy; it may only be cancelled")
        }
        // The chooser belongs to the document that opened it: a frame that
        // shows another one since gets no files, whatever its verdict.
        guard let current = frame.info, Self.isSameDocument(info, current) else {
            throw BrowserReplDriverError(code: "stale", message: "The frame the file chooser opened in shows another document since, so the files would go to a page that did not ask for them; it may only be cancelled")
        }
        guard isActive(in: webView) else { return }
        let recorded = BrowserReplFrameDocument(info: info)
        if let reason = blockReason(recorded, in: webView) {
            throw BrowserReplDriverError(code: "blocked", message: "The file chooser opened in a frame showing \(recorded.origin ?? recorded.place), which the domain policy blocks: \(reason); it may only be cancelled")
        }
        try await authorize(frame, in: webView)
    }

    /// Whether two of WebKit's records of one frame name the same document:
    /// by WebKit's document id (`_documentIdentifier`) when both carry one,
    /// else by URL and origin.
    static func isSameDocument(_ lhs: WKFrameInfo, _ rhs: WKFrameInfo) -> Bool {
        if let left = documentID(of: lhs), let right = documentID(of: rhs) { return left == right }
        return lhs.request.url == rhs.request.url && BrowserReplFrameDocument(info: lhs) == BrowserReplFrameDocument(info: rhs)
    }

    /// WebKit's id of the document `info` recorded
    /// (`-[WKFrameInfo _documentIdentifier]`), or nil where WebKit has none.
    public static func documentID(of info: WKFrameInfo) -> String? {
        let selector = NSSelectorFromString("_documentIdentifier")
        guard info.responds(to: selector) else { return nil }
        return (info.value(forKey: "_documentIdentifier") as? UUID)?.uuidString
    }

    /// The frames whose recorded documents the policy blocks.
    public func blocked(_ frames: [BrowserReplFrame], in webView: WKWebView) -> [(frame: BrowserReplFrame, reason: String)] {
        guard isActive(in: webView) else { return [] }
        return frames.compactMap { frame in
            recordedBlockReason(of: frame, in: webView).map { (frame, $0) }
        }
    }

    // MARK: - Private

    private static let originArgument = "__cmuxDocumentOrigin"
    private static let placeArgument = "__cmuxDocumentPlace"
    private static let localArgument = "__cmuxDocumentLocal"
    private static let opaqueArgument = "__cmuxDocumentOpaque"
    private static let movedMarker = "__cmuxDocumentMoved__"

    /// Runs first in every gated call. Only unforgeable `location` members
    /// and string operators: the content world's other globals may belong
    /// to agent code. A local or opaque document must also be the same one:
    /// its `href` is the approved URL followed by its own fragment.
    private static let documentCheck = """
    if (location.origin !== \(originArgument) || location.protocol + "//" + location.host !== \(placeArgument)
      || (location.origin === "file://" || location.protocol === "file:" ? location.href : null)
        !== (\(localArgument) === null ? null : \(localArgument) + location.hash)
      || (location.origin === "null" && (location.protocol === "data:" || location.protocol === "about:" || location.protocol === "blob:") ? location.href : null)
        !== (\(opaqueArgument) === null ? null : \(opaqueArgument) + location.hash)) return "\(movedMarker)";

    """

    /// `body` in a scope of its own, after the document check: what it
    /// declares (a hoisted `function location() {}`, a `var` or `let` of an
    /// argument's name) shadows only its own names, never the `location`
    /// and arguments the check reads.
    static func scoped(_ body: String) -> String {
        "return await (async () => {\n\(body)\n})();\n"
    }

    private static let readSource = """
    const local = location.origin === "file://" || location.protocol === "file:";
    const opaque = location.origin === "null" && (location.protocol === "data:" || location.protocol === "about:" || location.protocol === "blob:");
    const href = location.href.slice(0, location.href.length - location.hash.length);
    return [location.origin, location.protocol + "//" + location.host, local ? href : null, opaque ? href : null];
    """

    /// The boxes of the main frame's child frames at `indexes` (their
    /// indexes in WebKit's frame tree). `window.frames` holds only the
    /// frames of the document's own tree, not those in shadow trees, and
    /// WebKit orders both lists the same way; so the indexes match only
    /// when the main frame has no frame in a shadow tree (`window.frames`
    /// is as long as the tree's `childCount`). Otherwise every box is
    /// unknown. With `effects`, also whether a frame element or an
    /// ancestor draws it outside its box, and whether any element samples
    /// what lies under it. Agent code shares no state with this world, and
    /// `window.frames`, `contentWindow` and computed styles come from the
    /// engine.
    private static let boxesSource = """
    if (window.frames.length !== childCount) return { boxes: indexes.map(() => null), escapes: [], backdrop: false };
    const owners = new Map();
    let backdrop = false;
    const styleOf = (el) => getComputedStyle(el);
    const drawsElsewhere = (cs) => (cs.getPropertyValue("filter") || "none") !== "none"
      || (cs.getPropertyValue("-webkit-box-reflect") || "none") !== "none";
    const visit = (root) => {
      for (const el of root.querySelectorAll("iframe, frame, object, embed")) {
        const w = el.contentWindow;
        if (w && !owners.has(w)) owners.set(w, el);
      }
      for (const el of root.querySelectorAll("*")) {
        if (effects && !backdrop) {
          const cs = styleOf(el);
          const value = cs.getPropertyValue("backdrop-filter") || cs.getPropertyValue("-webkit-backdrop-filter") || "none";
          if (value !== "none") backdrop = true;
        }
        if (el.shadowRoot) visit(el.shadowRoot);
      }
    };
    visit(document);
    const escapes = [];
    const boxes = indexes.map((i, n) => {
      const target = window.frames[i];
      const el = target ? owners.get(target) : null;
      if (!el) return null;
      if (effects) {
        for (let node = el; node; node = node.parentNode || node.host) {
          if (node.nodeType === 1 && drawsElsewhere(styleOf(node))) { escapes.push(n); break; }
        }
      }
      const r = el.getBoundingClientRect();
      return { x: r.left, y: r.top, width: r.width, height: r.height };
    });
    return { boxes, escapes, backdrop };
    """

    /// The frame's own position in its parent's `window.frames` (-1 in a
    /// shadow tree) and that list's length.
    private static let positionSource = """
    const p = window.parent;
    let position = -1;
    const length = p === window ? 0 : p.length;
    for (let i = 0; i < length; i++) if (p[i] === window) { position = i; break; }
    return { position, length };
    """

    /// Makes the frame elements at `positions` in `window.frames` (and,
    /// with `shadow`, every frame element in a shadow tree) inert, and
    /// watches their `inert` attribute until the release. The state lives
    /// in this content world, which page and agent code cannot reach.
    private static let inputGuardSource = """
    if (window.frames.length !== length) return { result: "changed" };
    const inLight = new Set();
    for (let i = 0; i < window.frames.length; i++) inLight.add(window.frames[i]);
    const owners = new Map();
    const shadowFrames = [];
    let found = 0;
    const visit = (root) => {
      for (const el of root.querySelectorAll("iframe, frame, object, embed")) {
        const w = el.contentWindow;
        if (!w) continue;
        found++;
        if (!owners.has(w)) owners.set(w, el);
        if (!inLight.has(w)) shadowFrames.push(el);
      }
      for (const el of root.querySelectorAll("*")) if (el.shadowRoot) visit(el.shadowRoot);
    };
    visit(document);
    const targets = [];
    for (const position of positions) {
      const w = window.frames[position];
      const el = w ? owners.get(w) : null;
      if (!el) return { result: "unknown" };
      targets.push(el);
    }
    if (shadow) {
      // A frame in a closed shadow root is out of reach.
      if (found < childCount) return { result: "unknown" };
      for (const el of shadowFrames) if (!targets.includes(el)) targets.push(el);
    }
    const entries = targets.map((el) => ({ el, had: el.hasAttribute("inert") }));
    for (const entry of entries) if (!entry.had) entry.el.setAttribute("inert", "");
    const listed = [];
    for (let i = 0; i < window.frames.length; i++) listed.push(window.frames[i]);
    const sameFrames = () => {
      if (window.frames.length !== listed.length) return false;
      for (let i = 0; i < listed.length; i++) if (window.frames[i] !== listed[i]) return false;
      return true;
    };
    const record = { entries, tampered: false, observer: null, listed, sameFrames, moved: false, mover: null };
    // Notes any point at which window.frames differs from the guarded list,
    // so a reorder the page undoes before the check still counts.
    record.mover = new MutationObserver(() => { if (!sameFrames()) record.moved = true; });
    record.mover.observe(document, { childList: true, subtree: true, attributes: true });
    // Puts a guard the page took off back before the page's script returns.
    record.observer = new MutationObserver(() => {
      record.tampered = true;
      for (const entry of entries) if (!entry.el.hasAttribute("inert")) entry.el.setAttribute("inert", "");
    });
    for (const entry of entries) record.observer.observe(entry.el, { attributes: true, attributeFilter: ["inert"] });
    const guards = globalThis.__cmuxInputGuards || (globalThis.__cmuxInputGuards = new Map());
    guards.set(token, record);
    return { result: "ok" };
    """

    /// Hides the frame elements at `indexes` in `window.frames` (matched as
    /// in ``boxesSource``) for a capture, and keeps them hidden until the
    /// release, putting the style back whenever the page changes it.
    private static let hideSource = """
    if (window.frames.length !== childCount) return { result: "changed" };
    const owners = new Map();
    const visit = (root) => {
      for (const el of root.querySelectorAll("iframe, frame, object, embed")) {
        const w = el.contentWindow;
        if (w && !owners.has(w)) owners.set(w, el);
      }
      for (const el of root.querySelectorAll("*")) if (el.shadowRoot) visit(el.shadowRoot);
    };
    visit(document);
    const props = ["visibility", "transition-property"];
    const entries = [];
    for (const i of indexes) {
      const w = window.frames[i];
      const el = w ? owners.get(w) : null;
      if (!el || !el.style) return { result: "unknown" };
      if (!entries.some((entry) => entry.el === el)) {
        entries.push({ el, saved: props.map((p) => [p, el.style.getPropertyValue(p), el.style.getPropertyPriority(p)]) });
      }
    }
    const hidden = (el) => el.style.getPropertyValue("visibility") === "hidden" && el.style.getPropertyPriority("visibility") === "important"
      && el.style.getPropertyValue("transition-property") === "none" && el.style.getPropertyPriority("transition-property") === "important";
    const hide = (el) => {
      el.style.setProperty("transition-property", "none", "important");
      el.style.setProperty("visibility", "hidden", "important");
    };
    for (const entry of entries) hide(entry.el);
    const record = { entries, hidden, tampered: false, observer: null };
    record.observer = new MutationObserver(() => {
      for (const entry of entries) if (!hidden(entry.el)) { record.tampered = true; hide(entry.el); }
    });
    for (const entry of entries) record.observer.observe(entry.el, { attributes: true, attributeFilter: ["style"] });
    const covers = globalThis.__cmuxCaptureHides || (globalThis.__cmuxCaptureHides = new Map());
    covers.set(token, record);
    return { result: "ok" };
    """

    /// Restores what ``hideSource`` hid and says whether the page changed it.
    private static let unhideSource = """
    const covers = globalThis.__cmuxCaptureHides;
    const record = covers && covers.get(token);
    if (!record) return { tampered: true };
    covers.delete(token);
    const pending = record.observer.takeRecords().length > 0;
    record.observer.disconnect();
    const tampered = record.tampered || pending || record.entries.some((entry) => !record.hidden(entry.el));
    for (const entry of record.entries) {
      for (const [p, value, priority] of entry.saved) {
        if (value) entry.el.style.setProperty(p, value, priority);
        else entry.el.style.removeProperty(p);
      }
    }
    return { tampered };
    """

    /// Whether `window.frames` is still, and was at every change since, the
    /// list the guard `token` held; see ``verifyInputGuards(_:in:)``.
    private static let inputVerifySource = """
    const guards = globalThis.__cmuxInputGuards;
    const record = guards && guards.get(token);
    if (!record) return { result: "missing" };
    if (record.mover.takeRecords().length > 0 && !record.sameFrames()) record.moved = true;
    record.mover.disconnect();
    return { result: record.moved || !record.sameFrames() ? "changed" : "ok" };
    """

    /// Takes a guard off: restores each element's own `inert` attribute and
    /// says whether the page changed it meanwhile.
    private static let inputReleaseSource = """
    const guards = globalThis.__cmuxInputGuards;
    const record = guards && guards.get(token);
    if (!record) return { tampered: true };
    guards.delete(token);
    record.mover.disconnect();
    const changed = record.observer.takeRecords().length > 0;
    record.observer.disconnect();
    const tampered = record.tampered || changed || record.entries.some((entry) => !entry.el.hasAttribute("inert"));
    for (const entry of record.entries) if (!entry.had) entry.el.removeAttribute("inert");
    return { tampered };
    """

    /// A JavaScript expression: whether the element in `variable` is one
    /// that holds a child browsing context (`<iframe>`, `<frame>`,
    /// `<object>`, `<embed>`), so the focus it has is in that frame. Every
    /// focus check (the gate's, the secret target's) uses this one list.
    /// String comparisons only: it runs in a world agent code cannot reach,
    /// and needs no global it could replace.
    public static func frameElementTest(_ variable: String) -> String {
        "(!!\(variable) && (" + frameElementTags.map { "\(variable).tagName === \"\($0)\"" }.joined(separator: " || ") + "))"
    }

    /// The elements that hold a child browsing context.
    static let frameElementTags = ["IFRAME", "FRAME", "OBJECT", "EMBED"]

    /// The frame's focus, and its own position in its parent's
    /// `window.frames` (-1 in a shadow tree) with that list's length.
    private static let focusSource = """
    const e = document.activeElement;
    const inner = \(frameElementTest("e"));
    const p = window.parent;
    let position = -1;
    const length = p === window ? 0 : p.length;
    for (let i = 0; i < length; i++) if (p[i] === window) { position = i; break; }
    return { inner, focused: !inner && (document.hasFocus() || (!!e && e !== document.body && e !== document.documentElement)), position, length };
    """

    /// Whether the parent's focused element (inside shadow trees too) is
    /// the frame element of the child at `index` in `window.frames`; null
    /// when that cannot be told (the list changed since the child read its
    /// place, or a focused frame element is in a shadow tree, where
    /// `window.frames` does not reach), which counts as focused.
    private static let ownerFocusSource = """
    let e = document.activeElement;
    while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;
    if (!\(frameElementTest("e"))) return false;
    if (window.frames.length !== length) return null;
    const w = e.contentWindow;
    if (index >= 0) return !!w && w === window.frames[index];
    for (let i = 0; i < window.frames.length; i++) if (window.frames[i] === w) return false;
    return null;
    """

    private struct BlockedTop {
        /// The main frame's child frame that is, or holds, `blocked`.
        let top: BrowserReplFrame
        let blocked: BrowserReplFrame
        let reason: String
    }

    /// Throws `stale` when `frames` may lack frames the page has: the main
    /// frame's document, or that of a frame whose child frames the read
    /// could not describe (``BrowserReplFrame/childFramesUnread``), holds
    /// more child frames (`window.frames`, read in the gate's world) than
    /// the tree has under it. A frame missing from the tree would look like
    /// no blocked frame at all, so the checks fail closed instead. The tree
    /// can hold more than `window.frames` (frames in shadow trees).
    private func requireWholeTree(_ frames: [BrowserReplFrame], in webView: WKWebView) async throws {
        guard let main = frames.first else { return }
        for frame in frames where frame.frameID == main.frameID || frame.childFramesUnread {
            let treeCount = frames.filter { $0.parentFrameID == frame.frameID }.count
            let documentCount: Int
            do {
                let value = try await probe(
                    "return window.frames.length;", arguments: [:], in: webView, frame: frame.info,
                    what: "frame \(frame.url) did not report its child frames"
                )
                guard let count = (value as? NSNumber)?.intValue else { throw Self.incompleteTree(frame, documentCount: nil, treeCount: treeCount) }
                documentCount = count
            } catch let error as BrowserReplDriverError {
                throw error
            } catch {
                // A frame that has gone took its child frames with it.
                if frame.info != nil, Self.isGoneFrame(error) { continue }
                throw Self.incompleteTree(frame, documentCount: nil, treeCount: treeCount)
            }
            if documentCount > treeCount {
                throw Self.incompleteTree(frame, documentCount: documentCount, treeCount: treeCount)
            }
        }
    }

    private static func incompleteTree(_ frame: BrowserReplFrame, documentCount: Int?, treeCount: Int?) -> BrowserReplDriverError {
        let counts = documentCount.map { " (its document has \($0) child frames, the tree \(treeCount ?? 0))" } ?? ""
        return BrowserReplDriverError(
            code: "stale",
            message: "WebKit's frame tree of this tab came back without some child frames of frame \(frame.url)\(counts), so input, captures and scripts that could reach other frames are refused while the domain policy is on; try again"
        )
    }

    /// The main frame's child frames that are or hold a blocked frame, one
    /// per child. Throws `blocked` when the main frame is blocked, or a
    /// blocked frame's place in the tree is unknown.
    ///
    /// - Parameters:
    ///   - alsoBlocked: Frames (`frameID` to reason) to count as blocked
    ///     whatever the tree recorded for them.
    ///   - requireAlsoBlocked: Throw `blocked` when one of `alsoBlocked` is
    ///     not in `frames`, instead of passing over it.
    private func blockedTops(
        _ frames: [BrowserReplFrame],
        in webView: WKWebView,
        alsoBlocked: [String: String] = [:],
        requireAlsoBlocked: Bool = false
    ) throws -> [BlockedTop] {
        var blockedFrames = blocked(frames, in: webView)
        for (id, reason) in alsoBlocked.sorted(by: { $0.key < $1.key }) where !blockedFrames.contains(where: { $0.frame.frameID == id }) {
            guard let frame = frames.first(where: { $0.frameID == id }) else {
                guard requireAlsoBlocked else { continue }
                throw BrowserReplDriverError(code: "blocked", message: "Frame \(id) showed a page the domain policy blocks (\(reason)) when the capture was prepared and is no longer in the tab's frame tree, so a capture could show it")
            }
            blockedFrames.append((frame, reason))
        }
        guard let main = frames.first, !blockedFrames.isEmpty else { return [] }
        if let entry = blockedFrames.first(where: { $0.frame.frameID == main.frameID }) {
            throw blocked(entry.frame, document: nil, reason: entry.reason)
        }
        let byID = Dictionary(frames.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        var tops: [BlockedTop] = []
        for entry in blockedFrames {
            var top = entry.frame
            while let parentID = top.parentFrameID, parentID != main.frameID, let parent = byID[parentID] {
                top = parent
            }
            guard top.parentFrameID == main.frameID else {
                throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.frame.url) shows a page the domain policy blocks (\(entry.reason)) and its position is unknown, so input and captures of this tab are refused")
            }
            if !tops.contains(where: { $0.top.frameID == top.frameID }) {
                tops.append(BlockedTop(top: top, blocked: entry.frame, reason: entry.reason))
            }
        }
        return tops
    }

    /// The boxes (CSS pixels of the main frame's viewport) of `tops`, in
    /// order, `nil` where unknown; see ``boxesSource``.
    private func boxes(
        of tops: [BlockedTop],
        in webView: WKWebView,
        frames: [BrowserReplFrame],
        effects: Bool
    ) async throws -> (boxes: [CGRect?], escapes: Set<String>, backdrop: Bool) {
        let mainID = frames.first?.frameID
        let childCount = frames.filter { $0.parentFrameID != nil && $0.parentFrameID == mainID }.count
        let value = try await probe(
            Self.boxesSource,
            arguments: ["indexes": tops.map(\.top.indexInParent), "childCount": childCount, "effects": effects],
            in: webView,
            frame: nil,
            what: "the page did not report its frames' positions"
        ) as? [String: Any] ?? [:]
        let list = value["boxes"] as? [Any] ?? []
        let boxes: [CGRect?] = tops.indices.map { index in
            guard index < list.count, let box = list[index] as? [String: Any],
                  let x = (box["x"] as? NSNumber)?.doubleValue, let y = (box["y"] as? NSNumber)?.doubleValue,
                  let width = (box["width"] as? NSNumber)?.doubleValue, let height = (box["height"] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        // An effect check that did not answer counts as drawing elsewhere.
        let escapeIndexes = (value["escapes"] as? [NSNumber])?.map(\.intValue) ?? (effects ? Array(tops.indices) : [])
        let escapes = Set(escapeIndexes.compactMap { $0 < tops.count ? tops[$0].top.frameID : nil })
        let backdrop = (value["backdrop"] as? Bool) ?? effects
        return (boxes, escapes, backdrop)
    }

    private func key(_ frame: BrowserReplFrame, _ webView: WKWebView) -> Key {
        if known.count > 4_096 { known.removeAll() }
        return Key(webView: ObjectIdentifier(webView), frameID: frame.info == nil ? "main" : frame.frameID)
    }

    private func read(_ frame: BrowserReplFrame, in webView: WKWebView) async throws -> BrowserReplFrameDocument {
        let value: Any?
        do {
            value = try await probe(Self.readSource, arguments: [:], in: webView, frame: frame.info, what: "frame \(frame.frameID) did not answer")
        } catch let error as BrowserReplDriverError {
            throw error
        } catch {
            throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) did not answer: \(error.localizedDescription)")
        }
        guard let read = value as? [Any], read.count == 4, let place = read[1] as? String else {
            throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) did not answer")
        }
        return BrowserReplFrameDocument(origin: read[0] as? String, place: place, local: read[2] as? String, opaque: read[3] as? String)
            .withMakers(frame: frame.info, in: webView)
    }

    /// Runs one of the gate's own scripts in its world, failing with
    /// `stale` when it has not answered in time (``BrowserReplScriptProbe``).
    private func probe(
        _ source: String,
        arguments: [String: Any],
        in webView: WKWebView,
        frame: WKFrameInfo?,
        what: String
    ) async throws -> Any? {
        try await prober.call(source, arguments: arguments, in: webView, frame: frame, contentWorld: world, what: what)
    }

    private func blocked(_ frame: BrowserReplFrame, document: BrowserReplFrameDocument?, reason: String) -> BrowserReplDriverError {
        let shown = document.map { $0.origin.flatMap { $0 == "null" ? nil : $0 } ?? $0.place } ?? frame.url
        if frame.info == nil || frame.parentFrameID == nil {
            return BrowserReplDriverError(code: "blocked", message: "The tab shows \(shown), which the domain policy blocks: \(reason)")
        }
        return BrowserReplDriverError(code: "blocked", message: "Frame \(frame.frameID) shows \(shown), which the domain policy blocks: \(reason)")
    }

    private static func isGoneFrame(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == WKErrorDomain && nsError.code == WKError.javaScriptInvalidFrameTarget.rawValue
    }

    private static func format(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", Double(value))
    }
}
