public import Foundation

/// What a REPL session reads, acts on or loads, as one typed identity: the
/// authority judges nothing else (``BrowserReplDocumentAuthority``).
public enum BrowserReplDocumentSubject: Sendable, Equatable {
    /// A URL a load would show: a navigation target (`tabs.open`,
    /// `tab.navigate`), a cookie call's URL, the page a navigation landed on.
    case load(String)
    /// The page a tab shows by its recorded URL (also the page a hibernated
    /// tab would load again when woken).
    case tabPage(String)
    /// A frame's document, as WebKit recorded it or as read in the frame,
    /// with the makers recorded for it when it is opaque.
    case document(BrowserReplFrameDocument)
}

/// A tab as the authority needs it: who created it, what its main frame
/// shows, which sessions drive it and the workspace that holds it.
public struct BrowserReplTabFacts: Sendable, Equatable {
    /// The tab's id, for messages.
    public var id: UUID?
    /// The URL the tab's main frame shows (WebKit's), or nil.
    public var mainFrameURL: URL?
    /// The live session that created the tab, or nil for a user's tab.
    public var creatorSessionID: String?
    /// The sessions attached to the tab.
    public var attachedSessionIDs: Set<String>
    /// The workspace that holds the tab, or nil when it cannot be told.
    public var workspaceID: UUID?

    public init(
        id: UUID? = nil,
        mainFrameURL: URL? = nil,
        creatorSessionID: String? = nil,
        attachedSessionIDs: Set<String> = [],
        workspaceID: UUID? = nil
    ) {
        self.id = id
        self.mainFrameURL = mainFrameURL
        self.creatorSessionID = creatorSessionID
        self.attachedSessionIDs = attachedSessionIDs
        self.workspaceID = workspaceID
    }
}

/// What a session wants to do with a tab (``BrowserReplMethodSpec/capability``).
/// Both need the tab to be the session's own or the user's, and in the
/// session's workspace (``BrowserReplDocumentAuthority/verdict(_:)``).
public enum BrowserReplTabCapability: String, Sendable, CaseIterable {
    /// Read, drive or configure the tab (every tab method but closing it).
    case use
    /// Close the tab: also only a tab the session created or is attached to.
    case close
}

/// One question to the authority: may the session, now, do `capability`
/// with `tab` and read or act on `subject` there.
public struct BrowserReplAccess: Sendable, Equatable {
    /// The document, frame or URL; nil when only the tab is judged.
    public var subject: BrowserReplDocumentSubject?
    /// The tab `subject` is in or the call names; nil when there is none
    /// (a URL to load in a new tab, a cookie URL).
    public var tab: BrowserReplTabFacts?
    /// What the session does with `tab`; nil when only `subject` is judged
    /// (an event the tab sends, a frame inside a tab already authorized).
    public var capability: BrowserReplTabCapability?

    public init(_ subject: BrowserReplDocumentSubject? = nil, in tab: BrowserReplTabFacts? = nil, capability: BrowserReplTabCapability? = nil) {
        self.subject = subject
        self.tab = tab
        self.capability = capability
    }
}

/// Why the authority refused an access: a protocol error code (`blocked`
/// for a document or URL, `denied` for a tab), the bare reason (for callers
/// that name the frame themselves) and the message the session gets.
public struct BrowserReplRefusal: Error, Sendable, Equatable {
    public var code: String
    public var reason: String
    public var message: String

    public init(code: String, reason: String, message: String) {
        self.code = code
        self.reason = reason
        self.message = message
    }

    public var driverError: BrowserReplDriverError {
        BrowserReplDriverError(code: code, message: message)
    }
}

/// The authority's answer.
public enum BrowserReplVerdict: Sendable, Equatable {
    case allowed
    case refused(BrowserReplRefusal)

    public var refusal: BrowserReplRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }

    /// The bare reason of a refusal, or nil when allowed.
    public var reason: String? { refusal?.reason }

    /// Throws the refusal as a driver error.
    public func check() throws {
        if let refusal { throw refusal.driverError }
    }
}

/// THE verdict for "may this session act on or read from this document,
/// frame, URL or tab now". Every decision of the driver and the tab
/// plumbing goes through ``verdict(_:)``: the domain policy, the session's
/// file roots (local files and documents of a local file's origin), the
/// makers of opaque documents (``BrowserReplDocumentProvenance``) and the
/// tab's ownership. A new decision site builds a ``BrowserReplAccess``; it
/// never calls the domain policy or the file sandbox itself.
public struct BrowserReplDocumentAuthority: Sendable {
    /// The session whose access is judged.
    public var sessionID: String
    /// The session's domain policy (inactive: none).
    public var policy: BrowserReplDomainPolicy
    /// The session's working and temporary directories (canonical), the
    /// only ones its tabs may show local files from; nil when not known
    /// here, and then local files are not judged.
    public var fileRoots: [String]?
    /// The workspace the session is bound to; nil when not known here.
    public var workspaceID: UUID?

    public init(sessionID: String, policy: BrowserReplDomainPolicy = BrowserReplDomainPolicy(), fileRoots: [String]? = nil, workspaceID: UUID? = nil) {
        self.sessionID = sessionID
        self.policy = policy
        self.fileRoots = fileRoots
        self.workspaceID = workspaceID
    }

    /// An authority that judges documents, URLs and loads by `policy`
    /// alone, for no session's tab: with no tab and no directories, no
    /// verdict it gives asks who the session is (only a tab capability
    /// does, and a check without a tab has none).
    public static func judging(_ policy: BrowserReplDomainPolicy) -> BrowserReplDocumentAuthority {
        BrowserReplDocumentAuthority(sessionID: "", policy: policy)
    }

    /// Whether the authority judges local documents (``BrowserReplDocumentSubject/document(_:)``)
    /// in `tab`: a tab the session did not create whose main frame does not
    /// show a web page. A tab the session created keeps other files out
    /// with content rules and its navigation checks; a web page cannot
    /// frame a local file.
    public func judgesLocalDocuments(in tab: BrowserReplTabFacts?) -> Bool {
        guard fileRoots != nil, let tab, tab.creatorSessionID != sessionID else { return false }
        let scheme = tab.mainFrameURL?.scheme?.lowercased()
        return scheme != "http" && scheme != "https"
    }

    /// Whether any document of `tab` can be refused: a policy is in force,
    /// or the tab's local documents are judged.
    public func isActive(in tab: BrowserReplTabFacts?) -> Bool {
        policy.isActive || judgesLocalDocuments(in: tab)
    }

    /// The verdict: the tab capability first, then the subject.
    public func verdict(_ access: BrowserReplAccess) -> BrowserReplVerdict {
        if let capability = access.capability, let tab = access.tab,
           let refusal = tabRefusal(capability, tab) {
            return .refused(refusal)
        }
        guard let subject = access.subject else { return .allowed }
        switch subject {
        case .load(let url):
            guard let reason = policy.blockReason(url) else { return .allowed }
            return .refused(BrowserReplRefusal(code: "blocked", reason: reason, message: "\(url) is blocked: \(reason)"))
        case .tabPage(let url):
            // A local file outside the session's directories (a user's tab,
            // or one a hibernated tab would load again), whatever the policy.
            if let roots = fileRoots,
               let reason = BrowserReplFileSandbox.localPageRefusal(url: url, documentOrigin: nil, roots: roots) {
                return .refused(BrowserReplRefusal(code: "blocked", reason: reason, message: reason))
            }
            guard !url.isEmpty, let reason = policy.blockReason(url) else { return .allowed }
            // The session cannot read a page it is refused, so only the
            // tab's live creator gets its address with credential values.
            let shown = BrowserReplPageURL.tabAddress(url, liveCreator: access.tab?.creatorSessionID, reader: sessionID, documentLocation: nil)
                .string(for: sessionID)
            return .refused(BrowserReplRefusal(
                code: "blocked",
                reason: reason,
                message: "the tab shows \(shown), which the domain policy blocks: \(reason); navigate it to an allowed page"
            ))
        case .document(let document):
            if let reason = policy.blockReason(document: document) {
                return .refused(BrowserReplRefusal(code: "blocked", reason: reason, message: reason))
            }
            guard judgesLocalDocuments(in: access.tab), let roots = fileRoots,
                  let reason = BrowserReplFrameGate.localBlockReason(document, roots: roots) else { return .allowed }
            return .refused(BrowserReplRefusal(code: "blocked", reason: reason, message: reason))
        }
    }

    /// Why the session may not do `capability` with `tab`, or nil.
    private func tabRefusal(_ capability: BrowserReplTabCapability, _ tab: BrowserReplTabFacts) -> BrowserReplRefusal? {
        let name = tab.id?.uuidString ?? "?"
        if let owner = tab.creatorSessionID, owner != sessionID {
            let reason = "the tab \(name) belongs to the REPL session \(Self.describeSession(owner)), which is still running"
            return BrowserReplRefusal(
                code: "denied",
                reason: reason,
                message: "\(reason); a session drives only the tabs it opened and the user's tabs (tabs.list({ all: true }) shows each tab's owner)"
            )
        }
        let isCreator = tab.creatorSessionID == sessionID
        // A session acts in its own workspace. Another workspace's tab needs
        // an attach a person grants, and cmux has no such grant yet, so it
        // is refused; a tab whose workspace cannot be told is refused too.
        if let workspaceID, !isCreator, tab.workspaceID != workspaceID {
            let reason = "the tab \(name) is in another workspace"
            return BrowserReplRefusal(
                code: "denied",
                reason: reason,
                message: "\(reason); a REPL session drives only the tabs of its own workspace (a person must grant a tab of another workspace, and cmux has no such grant yet): open the page with tabs.open, or move the tab into this workspace"
            )
        }
        // A user's tab closes only through a session that drives it.
        if capability == .close, !isCreator, !tab.attachedSessionIDs.contains(sessionID) {
            let reason = "the tab \(name) is the user's and this session does not drive it"
            return BrowserReplRefusal(
                code: "denied",
                reason: reason,
                message: "\(reason); a session closes only the tabs it opened and the user's tabs it attached with tabs.use"
            )
        }
        return nil
    }

    /// A session's name, and its workspace, for messages.
    static func describeSession(_ instanceID: String) -> String {
        guard let key = BrowserReplSessionKey(instanceID: instanceID) else { return "\"\(instanceID)\"" }
        return "\"\(key.name)\" (workspace \(key.workspaceID.uuidString))"
    }
}

/// How `tabs.list` shows a tab to a session (``BrowserReplDocumentAuthority/listing(of:)``).
public enum BrowserReplTabListing: Sendable, Equatable {
    /// The session may use the tab: listed with its data store.
    case usable
    /// Another running session created the tab: listed with that session's
    /// instance id, without its data store, and not usable.
    case ownedByAnotherSession(String)
    /// Not listed.
    case hidden
}

/// A tab whose data store `tabs.open({ dataStore })` may name: the tab as
/// the authority judges it and the id of the store it uses.
public struct BrowserReplDataStoreCandidate<Store> {
    public var tab: BrowserReplTabFacts
    public var storeID: String
    public var store: Store

    public init(tab: BrowserReplTabFacts, storeID: String, store: Store) {
        self.tab = tab
        self.storeID = storeID
        self.store = store
    }
}

extension BrowserReplDocumentAuthority {
    /// How `tabs.list` shows `tab` to the session: a tab it may use
    /// (``BrowserReplTabCapability/use``) with its data store; another
    /// running session's tab of the session's workspace by that session,
    /// without its store; any other tab not at all. A tab of another
    /// workspace is not listed (a person must grant one, and cmux has no
    /// such grant yet), so neither is its profile's store.
    public func listing(of tab: BrowserReplTabFacts) -> BrowserReplTabListing {
        if verdict(BrowserReplAccess(in: tab, capability: .use)) == .allowed { return .usable }
        if let owner = tab.creatorSessionID, owner != sessionID, isInWorkspace(tab) { return .ownedByAnotherSession(owner) }
        return .hidden
    }

    /// The store of the first candidate whose store is `id` and whose tab
    /// the session may use (``BrowserReplTabCapability/use``), or nil: a
    /// store reaches a session only through a tab it may drive, never one
    /// of another workspace or another running session.
    public func dataStore<Store>(_ id: String, among candidates: [BrowserReplDataStoreCandidate<Store>]) -> Store? {
        candidates.first { candidate in
            candidate.storeID == id && verdict(BrowserReplAccess(in: candidate.tab, capability: .use)) == .allowed
        }?.store
    }

    /// The verdict on the page `tab` landed on after a navigation, a
    /// history step or a reload the session started
    /// (``BrowserReplMethodSpec/judgesLandedPage``): judged as the tab's page
    /// (``BrowserReplDocumentSubject/tabPage(_:)``), so a local file outside
    /// the session's directories is refused whatever the policy. A user's
    /// tab is never navigated away for it; the call fails.
    public func landedPage(_ url: String, in tab: BrowserReplTabFacts?) -> BrowserReplVerdict {
        guard let refusal = verdict(BrowserReplAccess(.tabPage(url), in: tab)).refusal else { return .allowed }
        let isCreator = tab?.creatorSessionID == sessionID
        let tail = isCreator ? "" : "; the tab is the user's, so it stays there and the session cannot read it"
        // The session cannot read a page it is refused, so only the tab's
        // live creator gets its address with credential values.
        let shown = BrowserReplPageURL.tabAddress(url, liveCreator: tab?.creatorSessionID, reader: sessionID, documentLocation: nil)
            .string(for: sessionID)
        return .refused(BrowserReplRefusal(
            code: refusal.code,
            reason: refusal.reason,
            message: "navigation to \(shown) was blocked: \(refusal.reason)\(tail)"
        ))
    }

    /// Whether `tab` is in the session's workspace (always, when the
    /// workspace is not known here).
    private func isInWorkspace(_ tab: BrowserReplTabFacts) -> Bool {
        guard let workspaceID else { return true }
        return tab.workspaceID == workspaceID
    }
}

extension BrowserReplPolicyBoard {
    /// The authority for `sessionID` as the board knows it: its published
    /// policy and file roots, and the workspace its instance id names
    /// (``BrowserReplSessionKey/init(instanceID:)``), so a tab capability
    /// it judges refuses a tab of another workspace as the driver does.
    public func authority(for sessionID: String) -> BrowserReplDocumentAuthority {
        BrowserReplDocumentAuthority(
            sessionID: sessionID,
            policy: policy(for: sessionID) ?? BrowserReplDomainPolicy(),
            fileRoots: fileRoots(for: sessionID),
            workspaceID: BrowserReplSessionKey(instanceID: sessionID)?.workspaceID
        )
    }
}
