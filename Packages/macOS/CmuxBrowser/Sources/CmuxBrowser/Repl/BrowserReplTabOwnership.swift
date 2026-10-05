/// A tab event a REPL session can take over from cmux's own UI.
public enum BrowserReplTabEvent: String, CaseIterable, Sendable {
    /// JavaScript `alert`, `confirm`, `prompt` and `beforeunload` dialogs.
    case dialog
    /// The open panel of an `<input type="file">`.
    case fileChooser = "filechooser"
    /// A download: kept in the temporary directory and reported to the session.
    case download
    /// Network events (`request`, `response`, `requestfinished`,
    /// `requestfailed`): a listener on the page.
    case network
}

/// Where a dialog, file chooser or download of one tab goes
/// (``BrowserReplTabOwnership/route(for:)``).
public enum BrowserReplEventRoute: Sendable, Equatable {
    /// cmux's own UI: no session takes the event.
    case user
    /// The one session that receives the event and may answer it.
    case session(String)
    /// Inputs of several sessions are in flight on the tab, so the page
    /// may have opened the event for any of them: no session gets it, and
    /// it is answered as an unhandled one (a dialog dismissed, a file
    /// chooser cancelled), never put in front of the user.
    case refused
}

/// The session whose input started a navigation that became a download,
/// and where that navigation went (``BrowserReplTabOwnership/takeDownloadClaim(navigation:at:)``).
public struct BrowserReplDownloadClaim: Sendable, Equatable {
    public var sessionID: String?
    public var source: BrowserReplDownloadSource

    public init(sessionID: String?, source: BrowserReplDownloadSource) {
        self.sessionID = sessionID
        self.source = source
    }
}

/// Where a download goes (``BrowserReplTabOwnership/downloadRoute(startedBy:source:policy:fileRoots:)``).
public enum BrowserReplDownloadRoute: Sendable, Equatable {
    /// The user's download location; no session gets it.
    case user
    /// The session, which reads it from the temporary directory.
    case session(BrowserReplNetworkRecipient)
    /// Cancelled: the creating session's tab may not load it.
    case refused(BrowserReplDownloadRefusal)
}

/// A session a network event goes to, and whether it gets the request's
/// and response's credential headers (``Swift/Dictionary/removingBrowserReplCredentialHeaders()``).
public struct BrowserReplNetworkRecipient: Sendable, Equatable {
    public let sessionID: String
    /// Only the tab's live creator sees `Cookie`, `Authorization` and the like.
    public let seesCredentials: Bool

    public init(sessionID: String, seesCredentials: Bool) {
        self.sessionID = sessionID
        self.seesCredentials = seesCredentials
    }
}

extension Dictionary where Key == String, Value == Any {
    /// A network event's payload as a session that did not create the tab
    /// gets it: without the request's and response's credential headers,
    /// and with the credential values in its URL, and in the URL-valued
    /// headers it keeps (`location`, `referer` and the like), replaced
    /// (``Swift/String/redactingBrowserReplURLCredentials()``).
    public func redactingBrowserReplCredentials() -> [String: Any] {
        var payload = self
        if let url = payload["url"] as? String {
            payload["url"] = url.redactingBrowserReplURLCredentials()
        }
        if let headers = payload["headers"] as? [String: String] {
            var kept = headers.removingBrowserReplCredentialHeaders()
            for (name, value) in kept where Self.urlValuedHeaderNames.contains(name.lowercased()) {
                kept[name] = value.redactingBrowserReplURLCredentials()
            }
            payload["headers"] = kept
        }
        return payload
    }

    /// Headers whose value is, or holds, a URL.
    private static var urlValuedHeaderNames: Set<String> {
        ["location", "content-location", "referer", "refresh", "link"]
    }
}

extension String {
    /// This URL with its credential values replaced by `redacted`: the
    /// userinfo (`user:password@`), and every query or fragment parameter
    /// whose name carries one, by the rule for credential headers
    /// (``BrowserReplFetcher/isCredentialHeader(_:)``: `token`, `auth`,
    /// `secret`, `session`, `password`, `signature`, `credential` and the
    /// like, so `access_token`, `id_token` and `X-Amz-Signature`) and the
    /// short names URLs use for one (`code`, `sig`, `key`, `otp` and the
    /// like). Other parameters, and the rest of the URL, stay as written.
    public func redactingBrowserReplURLCredentials() -> String {
        var rest = Substring(self)
        var result = ""
        // The scheme and authority: drop a userinfo.
        if let schemeEnd = rest.range(of: "://") {
            result += rest[..<schemeEnd.upperBound]
            rest = rest[schemeEnd.upperBound...]
            let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
            let authority = rest[..<authorityEnd]
            if let at = authority.lastIndex(of: "@") {
                result += "redacted@"
                result += authority[authority.index(after: at)...]
            } else {
                result += authority
            }
            rest = rest[authorityEnd...]
        }
        // The path as written, then the query and the fragment parameter by
        // parameter (any text before the first `?` or `#` in a header value
        // such as `refresh` stays as it is).
        guard let start = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return result + rest }
        result += rest[..<start]
        rest = rest[start...]
        var parameter = ""
        for character in rest {
            if character == "?" || character == "#" || character == "&" || character == ";" {
                result += Self.redactingBrowserReplCredentialParameter(parameter)
                result.append(character)
                parameter = ""
            } else {
                parameter.append(character)
            }
        }
        return result + Self.redactingBrowserReplCredentialParameter(parameter)
    }

    /// `name=value` with `value` replaced when `name` carries a credential.
    private static func redactingBrowserReplCredentialParameter(_ parameter: String) -> String {
        guard let equals = parameter.firstIndex(of: "=") else { return parameter }
        let rawName = String(parameter[..<equals])
        let name = (rawName.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawName).lowercased()
        guard BrowserReplFetcher.isCredentialHeader(name) || browserReplCredentialParameterNames.contains(name) else {
            return parameter
        }
        return rawName + "=redacted"
    }

    /// Short query names that carry a credential without saying so in the
    /// header rule's words.
    private static var browserReplCredentialParameterNames: Set<String> {
        ["code", "sig", "key", "jwt", "otp", "pass", "pwd", "sid", "ticket", "assertion", "samlresponse", "samlrequest"]
    }
}

extension Dictionary where Key == String, Value == String {
    /// Header names whose values sign the user in: never shown to a session
    /// that did not create the tab.
    static var browserReplCredentialHeaderNames: Set<String> {
        ["cookie", "set-cookie", "set-cookie2", "authorization", "proxy-authorization", "x-api-key", "x-auth-token", "x-csrf-token", "x-xsrf-token"]
    }

    /// These headers (names lowercase) without the credential ones: the
    /// standard names, and every name that says it carries one, by the rule
    /// `fetch` applies when a redirect leaves the origin
    /// (``BrowserReplFetcher/isCredentialHeader(_:)``: `auth`, `token`,
    /// `secret`, `session`, `password`, `signature` and the like).
    public func removingBrowserReplCredentialHeaders() -> [String: String] {
        filter { header in
            !Self.browserReplCredentialHeaderNames.contains(header.key.lowercased())
                && !BrowserReplFetcher.isCredentialHeader(header.key)
        }
    }
}

/// Decides, for one browser tab that REPL sessions drive, whether the
/// sessions or the user's normal UI answer its dialogs, file choosers,
/// downloads, permission requests and insecure-HTTP prompts.
///
/// A session's behaviors apply to a tab it created (`tabs.open`, and popups
/// of such a tab) while that session stays attached. Any other tab is the
/// user's (one the user opened, or one a finished run kept): it keeps cmux's
/// normal UI, except for an event an attached session registered a handler
/// for on that page (`tab.handleEvents`, sent for `page.on("dialog")`,
/// `waitForEvent("download")` and the like); only that event goes to the
/// sessions.
///
/// A dialog or file chooser the page opens while it handles a session's own
/// input (a click, key, drag or navigation the session sent) goes to that
/// session too, also in a user's tab: the agent caused it, so cmux's UI
/// must neither come up in front of the user nor leave the agent waiting
/// for an answer only the user can give. Downloads keep the user's location.
///
/// A routed event goes to one session (``route(for:)``), and only that
/// session may answer it: a second session driving the same tab never sees
/// or answers a dialog, file chooser or download routed to another. What
/// the page opens while it handles one session's input is that session's,
/// also when another session has a handler for it. WebKit does not say
/// which input an event came from, so while inputs of two sessions are in
/// flight at once no event, popup or request goes to either of them.
///
/// A tab a session created is that session's alone while it lives: no other
/// session may drive it (``ownerRefusing(_:)``). Network events go only to
/// the sessions they belong to (``networkRecipients(event:requestID:)``).
public struct BrowserReplTabOwnership: Sendable, Equatable {
    /// The attached session that created the tab, if any.
    public private(set) var creatorSessionID: String?
    private var attachedSessionIDs: Set<String> = []
    private var handledEvents: [String: Set<BrowserReplTabEvent>] = [:]
    /// Sessions with a handler, in the order they registered one.
    private var handlerOrder: [String] = []
    /// Sessions whose input the page is handling, latest last.
    private var inputSessionIDs: [String] = []
    /// The sessions each open request's events go to, oldest request first.
    private var requestRecipients: [TrackedRequest] = []
    private struct TrackedRequest: Sendable, Equatable {
        let requestID: String
        var sessionIDs: Set<String>
    }
    /// Open requests remembered at most; a later event of an older one goes
    /// only to the creator and the sessions with a network listener.
    static let maximumTrackedRequests = 1000
    /// The latest navigation WebKit asked about in each frame (by frame
    /// key), with the session whose input started it (`nil`: the user's or
    /// the page's own), so the download it turns into (its response may
    /// arrive after the input ended) can be told to be that session's
    /// (``takeDownloadStarter(navigation:at:)``,
    /// ``takeDownloadStarter(responseInFrame:at:)``). A later navigation in
    /// the frame replaces it, whatever its URL.
    private var latestNavigations: [String: NavigationStart] = [:]
    private struct NavigationStart: Sendable, Equatable {
        let navigation: Int
        var sessionID: String?
        let at: ContinuousClock.Instant
        /// The URLs the navigation went through, and who started it.
        var source = BrowserReplDownloadSource()
    }
    /// How long a started navigation can claim the download it becomes.
    static let navigationStartLifetime: Duration = .seconds(60)
    static let maximumNavigationStarts = 64

    public init() {}

    /// Records that `sessionID` drives the tab.
    public mutating func attach(sessionID: String) {
        attachedSessionIDs.insert(sessionID)
    }

    /// Records that `sessionID` created the tab. The first creator wins.
    public mutating func markCreated(by sessionID: String) {
        attachedSessionIDs.insert(sessionID)
        if creatorSessionID == nil { creatorSessionID = sessionID }
    }

    /// Records that `sessionID` left the tab. When it created the tab, the
    /// tab becomes the user's for the sessions that remain.
    /// - Returns: Whether `sessionID` was the tab's creator: what it put in
    ///   the tab (its clipboard) must not outlive it.
    @discardableResult
    public mutating func detach(sessionID: String) -> Bool {
        attachedSessionIDs.remove(sessionID)
        handledEvents.removeValue(forKey: sessionID)
        handlerOrder.removeAll { $0 == sessionID }
        inputSessionIDs.removeAll { $0 == sessionID }
        for (frame, start) in latestNavigations where start.sessionID == sessionID {
            latestNavigations[frame]?.sessionID = nil
        }
        for index in requestRecipients.indices { requestRecipients[index].sessionIDs.remove(sessionID) }
        guard creatorSessionID == sessionID else { return false }
        creatorSessionID = nil
        return true
    }

    /// The live session that created the tab, when that is not `sessionID`:
    /// `sessionID` may not drive the tab. `nil` for the creator itself and
    /// for a user's tab (one no live session created).
    public func ownerRefusing(_ sessionID: String) -> String? {
        guard isSessionOwned, let creatorSessionID, creatorSessionID != sessionID else { return nil }
        return creatorSessionID
    }

    /// The sessions a network event of `requestID` goes to, in session id
    /// order: the tab's live creator, a session with a network listener
    /// on the tab, and a session whose input the page was handling when the
    /// request started (the rest of that request follows it). Only the
    /// creator sees credential headers.
    /// - Parameter event: `request` starts a request; `requestfinished` and
    ///   `requestfailed` end it.
    public mutating func networkRecipients(event: String, requestID: String) -> [BrowserReplNetworkRecipient] {
        let creator = isSessionOwned ? creatorSessionID : nil
        var sessions = Set(handledEvents.filter { $0.value.contains(.network) }.keys)
        if let creator { sessions.insert(creator) }
        let tracked = requestRecipients.firstIndex { $0.requestID == requestID }
        if event == "request" {
            // Only a request one session's input alone may have started
            // follows that session; with two sessions acting, neither.
            let started = sessions.union(inputSessionID.map { [$0] } ?? [])
            if let tracked { requestRecipients.remove(at: tracked) }
            requestRecipients.append(TrackedRequest(requestID: requestID, sessionIDs: started))
            if requestRecipients.count > Self.maximumTrackedRequests { requestRecipients.removeFirst() }
            sessions = started
        } else if let tracked {
            sessions.formUnion(requestRecipients[tracked].sessionIDs)
            if event == "requestfinished" || event == "requestfailed" { requestRecipients.remove(at: tracked) }
        }
        return sessions.filter { attachedSessionIDs.contains($0) }.sorted().map {
            BrowserReplNetworkRecipient(sessionID: $0, seesCredentials: $0 == creator)
        }
    }

    /// Records that the page is handling input `sessionID` sent; dialogs and
    /// file choosers it opens until ``endInput(sessionID:)`` go to that
    /// session. Ignored for a session that is not attached.
    public mutating func beginInput(sessionID: String) {
        guard attachedSessionIDs.contains(sessionID) else { return }
        inputSessionIDs.append(sessionID)
    }

    /// The session whose input the page is handling now, if exactly one
    /// session's input is in flight. `nil` when none is, and when inputs of
    /// several sessions are (``isInputAmbiguous``): an event the page opens
    /// then cannot be told to be one session's.
    public var inputSessionID: String? {
        guard let first = inputSessionIDs.first, inputSessionIDs.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Whether inputs of more than one session are in flight on the tab.
    public var isInputAmbiguous: Bool {
        guard let first = inputSessionIDs.first else { return false }
        return inputSessionIDs.contains { $0 != first }
    }

    /// Ends one ``beginInput(sessionID:)``.
    public mutating func endInput(sessionID: String) {
        if let index = inputSessionIDs.lastIndex(of: sessionID) {
            inputSessionIDs.remove(at: index)
        }
    }

    /// Replaces the events `sessionID` handles on this tab. Ignored for a
    /// session that is not attached.
    public mutating func setHandledEvents(_ events: Set<BrowserReplTabEvent>, for sessionID: String) {
        guard attachedSessionIDs.contains(sessionID) else { return }
        handledEvents[sessionID] = events.isEmpty ? nil : events
        if events.isEmpty {
            handlerOrder.removeAll { $0 == sessionID }
        } else if !handlerOrder.contains(sessionID) {
            handlerOrder.append(sessionID)
        }
    }

    /// Whether an attached session created the tab, so the session's own
    /// policies (permission answers from `session.configure`, no
    /// insecure-HTTP prompt) apply.
    public var isSessionOwned: Bool {
        guard let creatorSessionID else { return false }
        return attachedSessionIDs.contains(creatorSessionID)
    }

    /// Whether `event` goes to a session instead of the user's UI.
    public func routesToSessions(_ event: BrowserReplTabEvent) -> Bool {
        recipient(for: event) != nil
    }

    /// Where `event` goes. In a tab a session created, the attached
    /// creator (only it drives the tab). Else a dialog or file chooser the
    /// page opens while it handles one session's input goes to that
    /// session, and to none while inputs of several sessions are in flight
    /// (``BrowserReplEventRoute/refused``); any other event goes to the
    /// session that registered a handler for it first, else to the user.
    public func route(for event: BrowserReplTabEvent) -> BrowserReplEventRoute {
        let creator = isSessionOwned ? creatorSessionID : nil
        if let creator, handledEvents[creator]?.contains(event) == true { return .session(creator) }
        if event != .download {
            if isInputAmbiguous { return .refused }
            if let acting = inputSessionID, attachedSessionIDs.contains(acting) { return .session(acting) }
        }
        if let handler = handlerOrder.first(where: { handledEvents[$0]?.contains(event) == true }) {
            return .session(handler)
        }
        if let creator { return .session(creator) }
        return .user
    }

    /// Where a dialog or file chooser that `document` (the frame that asked,
    /// as WebKit recorded it) opened goes, given each session's domain
    /// policy (`nil`: none): ``route(for:)``, except that a session whose
    /// policy blocks that document never gets it, so it neither reads the
    /// blocked page's message nor answers it. In a tab that session created,
    /// and while the page handles that session's input, it is answered as
    /// an unhandled one (``BrowserReplEventRoute/refused``): the session's
    /// doing must not bring cmux's UI up in front of the user. Otherwise
    /// (the session's handler on a user's tab) it goes to the user, as it
    /// would without that handler.
    public func route(
        for event: BrowserReplTabEvent,
        from document: BrowserReplFrameDocument,
        policy: (String) -> BrowserReplDomainPolicy?
    ) -> BrowserReplEventRoute {
        let route = route(for: event)
        guard case .session(let sessionID) = route,
              policy(sessionID)?.blockReason(document: document) != nil else { return route }
        let creator = isSessionOwned ? creatorSessionID : nil
        return sessionID == creator || sessionID == inputSessionID ? .refused : .user
    }

    /// The one session `event` goes to (``route(for:)``), or `nil` when no
    /// session gets it.
    public func recipient(for event: BrowserReplTabEvent) -> String? {
        if case .session(let sessionID) = route(for: event) { return sessionID }
        return nil
    }

    /// Records navigation `navigation` (an id the caller gives WebKit's
    /// navigation action, unique for the tab) in `frame` as the frame's
    /// latest: the acting session's when exactly one session's input is in
    /// flight (``inputSessionID``), otherwise nobody's. A redirect
    /// (`continuing` true) is the same navigation and keeps the session that
    /// started it, also after its input ended.
    public mutating func noteNavigationAction(
        _ navigation: Int,
        frame: String,
        url: String? = nil,
        initiator: BrowserReplFrameDocument? = nil,
        continuing: Bool = false,
        at now: ContinuousClock.Instant = .now
    ) {
        let acting = inputSessionID.flatMap { attachedSessionIDs.contains($0) ? $0 : nil }
        let previous = latestNavigations[frame].flatMap { now - $0.at > Self.navigationStartLifetime ? nil : $0 }
        let sessionID = acting ?? (continuing ? previous?.sessionID : nil)
        // A redirect goes on from where the navigation went; a new one starts over.
        var source = continuing ? previous?.source ?? BrowserReplDownloadSource(initiator: initiator) : BrowserReplDownloadSource(initiator: initiator)
        if let url { source.went(to: url) }
        latestNavigations[frame] = NavigationStart(navigation: navigation, sessionID: sessionID, at: now, source: source)
        if latestNavigations.count > Self.maximumNavigationStarts,
           let oldest = latestNavigations.min(by: { $0.value.at < $1.value.at })?.key {
            latestNavigations.removeValue(forKey: oldest)
        }
    }

    /// The session whose input started navigation `navigation`, which
    /// WebKit turned into a download itself (its navigation action), within
    /// ``navigationStartLifetime``; the record is used up. `nil` when no
    /// session's input started it (the user's, or the page's own), or when
    /// a later navigation in its frame replaced it.
    public mutating func takeDownloadStarter(navigation: Int, at now: ContinuousClock.Instant = .now) -> String? {
        takeDownloadClaim(navigation: navigation, at: now)?.sessionID
    }

    /// ``takeDownloadStarter(navigation:at:)`` with where the navigation
    /// went (``BrowserReplDownloadSource``); `nil` when no navigation of
    /// that id is recorded.
    public mutating func takeDownloadClaim(navigation: Int, at now: ContinuousClock.Instant = .now) -> BrowserReplDownloadClaim? {
        guard let frame = latestNavigations.first(where: { $0.value.navigation == navigation })?.key else { return nil }
        return take(frame, at: now)
    }

    /// The session whose input started the latest navigation in `frame`,
    /// whose response became a download, within ``navigationStartLifetime``;
    /// the record is used up. A navigation the user or the page started in
    /// the frame after the session's (whatever its URL) replaced the record,
    /// so its download is not the session's.
    public mutating func takeDownloadStarter(responseInFrame frame: String, at now: ContinuousClock.Instant = .now) -> String? {
        take(frame, at: now)?.sessionID
    }

    /// ``takeDownloadStarter(responseInFrame:at:)`` with where the
    /// navigation went (``BrowserReplDownloadSource``); `nil` when the frame
    /// has no navigation recorded.
    public mutating func takeDownloadClaim(responseInFrame frame: String, at now: ContinuousClock.Instant = .now) -> BrowserReplDownloadClaim? {
        take(frame, at: now)
    }

    private mutating func take(_ frame: String, at now: ContinuousClock.Instant) -> BrowserReplDownloadClaim? {
        guard let start = latestNavigations[frame] else { return nil }
        latestNavigations[frame]?.sessionID = nil
        let live = now - start.at <= Self.navigationStartLifetime
        return BrowserReplDownloadClaim(sessionID: live ? start.sessionID : nil, source: start.source)
    }

    /// The session a download goes to (it stays in the temporary directory
    /// and the session reads it), or `nil` for the user's download location.
    /// In a tab a session created, the attached creator, or the session
    /// with a handler for downloads there. In a user's tab only `startedBy`,
    /// the session whose own input started it, and only while it has a
    /// handler for downloads: a file the user downloads never reaches a
    /// session that listens.
    public func downloadRecipient(startedBy: String?) -> String? {
        if isSessionOwned { return recipient(for: .download) }
        guard let startedBy, attachedSessionIDs.contains(startedBy),
              handledEvents[startedBy]?.contains(.download) == true else { return nil }
        return startedBy
    }

    /// The session a download goes to (``downloadRecipient(startedBy:)``),
    /// and whether it gets the download's URL as written: only the tab's
    /// live creator does. Any other recipient (a session whose own input
    /// started a download in a user's tab) gets it with its credential
    /// values replaced, as network events give it
    /// (``Swift/Dictionary/redactingBrowserReplCredentials()``).
    public func downloadDelivery(startedBy: String?) -> BrowserReplNetworkRecipient? {
        guard let recipient = downloadRecipient(startedBy: startedBy) else { return nil }
        let creator = isSessionOwned ? creatorSessionID : nil
        return BrowserReplNetworkRecipient(sessionID: recipient, seesCredentials: recipient == creator)
    }

    /// Where a download goes, given where it came from (`source`) and each
    /// session's domain policy and working and temporary directories
    /// (`nil`: none set): to ``downloadDelivery(startedBy:)``'s session when
    /// that session may read every place it came from
    /// (``BrowserReplDownloadSource/refusal(policy:fileRoots:)``). Else, in
    /// a tab that session created, it is refused (cancelled; that tab never
    /// loads what its policy blocks), and in a user's tab it keeps the
    /// user's download location, as one no session's input started does.
    public func downloadRoute(
        startedBy: String?,
        source: BrowserReplDownloadSource,
        policy: (String) -> BrowserReplDomainPolicy?,
        fileRoots: (String) -> [String]?
    ) -> BrowserReplDownloadRoute {
        guard let delivery = downloadDelivery(startedBy: startedBy) else { return .user }
        if let reason = source.refusal(policy: policy(delivery.sessionID), fileRoots: fileRoots(delivery.sessionID) ?? []) {
            return isSessionOwned && delivery.sessionID == creatorSessionID ? .refused(reason) : .user
        }
        return .session(delivery)
    }

    /// Parses `tab.handleEvents` names.
    /// - Returns: `nil` when a name is not a ``BrowserReplTabEvent``.
    public static func events(named names: [String]) -> Set<BrowserReplTabEvent>? {
        var events = Set<BrowserReplTabEvent>()
        for name in names {
            guard let event = BrowserReplTabEvent(rawValue: name) else { return nil }
            events.insert(event)
        }
        return events
    }
}
