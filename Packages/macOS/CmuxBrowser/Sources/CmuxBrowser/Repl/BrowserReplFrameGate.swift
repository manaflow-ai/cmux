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

    public init(origin: String?, place: String, makers: [BrowserReplDocumentMaker]? = nil, local: String? = nil) {
        self.origin = origin
        self.place = place
        self.makers = makers
        self.local = local
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.origin == rhs.origin && lhs.place == rhs.place && lhs.local == rhs.local
    }

    /// `url` without its fragment when the document is local (its origin
    /// is a local file's, or `url` is a `file:` URL), else nil.
    static func local(url: URL?, origin: String?) -> String? {
        guard origin?.lowercased() == "file://" || url?.scheme?.lowercased() == "file" else { return nil }
        let text = url?.absoluteString ?? ""
        return text.firstIndex(of: "#").map { String(text[..<$0]) } ?? text
    }

    /// Whether the document has an opaque origin and a URL that names no
    /// host (`data:`, `about:`, `blob:`): neither tells who wrote it.
    public var isOpaque: Bool {
        (origin == nil || origin == "null") && Self.hostlessPlaces.contains(place)
    }

    static let hostlessPlaces: Set<String> = ["about://", "data://", "blob://"]

    /// The document WebKit recorded for a frame when the tree was read; a
    /// frame that navigated since shows another one.
    @MainActor
    public init(info: WKFrameInfo) {
        origin = Self.origin(of: info.securityOrigin)
        place = Self.place(of: info.request.url)
        local = Self.local(url: info.request.url, origin: origin)
        if isOpaque { makers = BrowserReplDocumentProvenance.makers(of: info) }
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
    /// origin and its URL's host must both be allowed: an `about:blank` or
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
        if let origin = document.origin, origin != "null", let reason = blockReason(origin + "/") {
            return reason
        }
        if document.isOpaque { return opaqueBlockReason(document) }
        if BrowserReplFrameDocument.hostlessPlaces.contains(document.place) { return nil }
        return blockReason(document.place + "/")
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
    /// For a tab the session did not create, the directories whose local
    /// files the session may read (its working and temporary directories);
    /// nil for the session's own tabs, whose content rules and navigation
    /// checks keep other files out. Set by the driver.
    ///
    /// In such a tab a frame that shows any other local document (a file
    /// outside the directories, or a document of a local file's origin
    /// under another URL, whose file cannot be told) is judged like a frame
    /// the policy blocks, whatever the policy
    /// (``BrowserReplFileSandbox/localPageRefusal(url:documentOrigin:roots:)``):
    /// a user's tab on a local page inside the directories may show such
    /// files in its child frames. Only a local document can show a local
    /// file in a frame, so a tab whose main frame shows a web page
    /// (`http`, `https`) is left to the policy alone.
    public var localDocumentRoots: @MainActor (WKWebView) -> [String]? = { _ in nil }

    /// The directories `webView`'s local documents are judged by, or nil
    /// when they are not judged (``localDocumentRoots``).
    private func localRoots(in webView: WKWebView) -> [String]? {
        if let scheme = webView.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" { return nil }
        return localDocumentRoots(webView)
    }

    /// Whether the gate judges `webView`'s frames: a domain policy is in
    /// force, or its local documents are judged (``localDocumentRoots``).
    public func isActive(in webView: WKWebView) -> Bool {
        policy.isActive || localRoots(in: webView) != nil
    }

    /// Why a frame of `webView` that shows `document` is refused: the
    /// policy blocks it, or it is a local document the session may not read.
    func blockReason(_ document: BrowserReplFrameDocument, in webView: WKWebView) -> String? {
        if let reason = policy.blockReason(document: document) { return reason }
        guard let local = document.local, let roots = localRoots(in: webView) else { return nil }
        return BrowserReplFileSandbox.localPageRefusal(url: local, documentOrigin: document.origin, roots: roots)
    }
    private let world: WKContentWorld
    /// Bounds each of the gate's own probes (a frame's document, its focus,
    /// the frame boxes); one that does not answer in time refuses the call
    /// with `stale`.
    private let prober: BrowserReplScriptProbe
    /// The document each frame last showed when the gate read it.
    private var known: [Key: BrowserReplFrameDocument] = [:]
    /// Holds back child-frame loads while guarded input or a capture is in
    /// flight; the navigation delegate honors it.
    let loadHold: BrowserReplSubframeLoadHold

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
    /// (the agent's page-world script, which the driver runs under the
    /// clipboard quarantine): a page's handler it sets off synchronously (a
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
        guard isActive(in: webView) else {
            return try await webView.browserReplCallAsyncJavaScript(body, arguments: arguments, in: frame.info, contentWorld: contentWorld, userGesture: userGesture)
        }
        let key = key(frame, webView)
        var expected = known[key]
            ?? frame.info.map { BrowserReplFrameDocument(info: $0) }
            ?? BrowserReplFrameDocument(url: webView.url)
        if blockReason(expected, in: webView) != nil, let current = try await authorize(frame, in: webView) {
            expected = current
        }
        var bound = arguments
        for _ in 0..<3 {
            bound[Self.originArgument] = expected.origin ?? NSNull()
            bound[Self.placeArgument] = expected.place
            bound[Self.localArgument] = expected.local ?? NSNull()
            let value = try await webView.browserReplCallAsyncJavaScript(
                Self.documentCheck + body,
                arguments: bound,
                in: frame.info,
                contentWorld: contentWorld,
                userGesture: userGesture
            )
            guard value as? String == Self.movedMarker else {
                known[key] = expected
                return value
            }
            guard let current = try await authorize(frame, in: webView) else { break }
            expected = current
        }
        throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) kept navigating; try again once it has loaded")
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

    /// Runs `command`, a Copy, Cut or Paste on the focused frame, only
    /// while no frame the policy blocks holds the focus, and gives its
    /// result back only if none holds it after the command either.
    ///
    /// The driver checks the focus before it delivers the key, but the
    /// page's own key handlers run before the command and can move the
    /// focus into a blocked frame (whose selection the command would copy,
    /// or into which it would paste the tab's clipboard), and a page can
    /// move it during the command. So the focus is checked again on a fresh
    /// tree right before the command, and after it before its result (the
    /// copied pasteboard) is taken. The page can still move the focus in its
    /// own web process between the last check and WebKit running the command.
    public func guardingFocus<T>(
        in webView: WKWebView,
        frames: @MainActor () async -> [BrowserReplFrame],
        _ command: () async throws -> T
    ) async throws -> T {
        guard isActive(in: webView) else { return try await command() }
        try await checkFocus(in: webView, frames: await frames())
        let value = try await command()
        do {
            try await checkFocus(in: webView, frames: await frames())
        } catch let error as BrowserReplDriverError where error.code == "blocked" {
            throw BrowserReplDriverError(code: "blocked", message: "\(error.message); the focus moved there during the command, so its result was discarded")
        }
        return value
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
        guard isActive(in: webView) else { return try await input() }
        return try await loadHold.holding(webView) {
            let guards = try await installInputGuards(in: webView, frames: await frames())
            let value: T
            do {
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
                    installed.append(InputGuard(parent: parent, token: token, guarded: entries.map(\.frame)))
                case "changed":
                    throw BrowserReplDriverError(code: "stale", message: "The page changed its frames while input to frame \(parent.url) was prepared; try again")
                default:
                    let entry = entries[0]
                    throw BrowserReplDriverError(code: "blocked", message: "Frame \(entry.frame.url) shows a page the domain policy blocks (\(entry.reason)) and its frame element cannot be held out of the input's reach, so input to this tab is refused")
                }
            }
        } catch {
            _ = await releaseInputGuards(installed, in: webView)
            throw error
        }
        return installed
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
        guard isActive(in: webView) else { return }
        let refusal = { (shown: String, reason: String) in
            BrowserReplDriverError(code: "blocked", message: "The file chooser opened in a frame showing \(shown), which the domain policy blocks: \(reason); it may only be cancelled")
        }
        let recorded = BrowserReplFrameDocument(info: info)
        if let reason = blockReason(recorded, in: webView) {
            throw refusal(recorded.origin ?? recorded.place, reason)
        }
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
        try await authorize(frame, in: webView)
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
    private static let movedMarker = "__cmuxDocumentMoved__"

    /// Runs first in every gated call. Only unforgeable `location` members
    /// and string operators: the content world's other globals may belong
    /// to agent code. A local document must also be the same one: its
    /// `href` is the approved URL followed by its own fragment.
    private static let documentCheck = """
    if (location.origin !== \(originArgument) || location.protocol + "//" + location.host !== \(placeArgument)
      || (location.origin === "file://" || location.protocol === "file:" ? location.href : null)
        !== (\(localArgument) === null ? null : \(localArgument) + location.hash)) return "\(movedMarker)";

    """

    private static let readSource = """
    const local = location.origin === "file://" || location.protocol === "file:";
    return [location.origin, location.protocol + "//" + location.host,
      local ? location.href.slice(0, location.href.length - location.hash.length) : null];
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
    const record = { entries, tampered: false, observer: null };
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

    /// Takes a guard off: restores each element's own `inert` attribute and
    /// says whether the page changed it meanwhile.
    private static let inputReleaseSource = """
    const guards = globalThis.__cmuxInputGuards;
    const record = guards && guards.get(token);
    if (!record) return { tampered: true };
    guards.delete(token);
    const changed = record.observer.takeRecords().length > 0;
    record.observer.disconnect();
    const tampered = record.tampered || changed || record.entries.some((entry) => !entry.el.hasAttribute("inert"));
    for (const entry of record.entries) if (!entry.had) entry.el.removeAttribute("inert");
    return { tampered };
    """

    /// The frame's focus, and its own position in its parent's
    /// `window.frames` (-1 in a shadow tree) with that list's length.
    private static let focusSource = """
    const e = document.activeElement;
    const inner = !!e && (e.tagName === "IFRAME" || e.tagName === "FRAME" || e.tagName === "OBJECT");
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
    if (!e || !(e.tagName === "IFRAME" || e.tagName === "FRAME" || e.tagName === "OBJECT" || e.tagName === "EMBED")) return false;
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
            message: "WebKit's frame tree of this tab came back without some child frames of frame \(frame.url)\(counts), so input and captures are refused while the domain policy is on; try again"
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
        guard let read = value as? [Any], read.count == 3, let place = read[1] as? String else {
            throw BrowserReplDriverError(code: "stale", message: "Frame \(frame.frameID) did not answer")
        }
        return BrowserReplFrameDocument(origin: read[0] as? String, place: place, local: read[2] as? String)
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
