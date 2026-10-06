import Foundation
import Testing

@testable import CmuxBrowser

/// One authority judges every document, URL and tab a session reaches, and
/// one table names the guards of every driver method and event.
@Suite("Browser REPL document authority")
struct BrowserReplDocumentAuthorityTests {
    private func policy(allowed: [String]? = nil, prohibited: [String] = [], locked: Bool = false) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.allowed = try allowed?.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.prohibited = try prohibited.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.locked = locked
        return policy
    }

    private let roots = ["/tmp/session-work"]

    @Test("Every driver method has a guard entry, and a method outside the table is refused")
    func everyMethodHasASpec() {
        for method in BrowserReplDriverMethod.allCases {
            let spec = BrowserReplMethodSpec.spec(for: method.rawValue)
            #expect(spec == method.spec, "\(method.rawValue) has no guard entry")
            // An explicit `none` always says why.
            if case .none(let reason) = method.spec.target { #expect(!reason.isEmpty, "\(method.rawValue)") }
            if case .none(let reason) = method.spec.page { #expect(!reason.isEmpty, "\(method.rawValue)") }
            if case .none(let reason) = method.spec.frames { #expect(!reason.isEmpty, "\(method.rawValue)") }
            if case .inFrame(let reason) = method.spec.frames { #expect(!reason.isEmpty, "\(method.rawValue)") }
            // Trusted input always has a frame check and a page check.
            if method.spec.guardsInput {
                #expect(method.spec.page == .tabPage, "\(method.rawValue)")
                #expect([.pointer, .drag, .focus].contains(method.spec.frames), "\(method.rawValue)")
            }
            // A page or frame check needs the tab the method acts on.
            if method.spec.page == .tabPage { #expect(method.spec.capability != nil, "\(method.rawValue)") }
        }
        for unknown in ["tab.evaluate", "frames.evaluate", "input.", "", "TAB.INFO", "tab.info "] {
            #expect(BrowserReplMethodSpec.spec(for: unknown) == nil, "\(unknown) must be refused")
        }
        #expect(BrowserReplMethodSpec.unknownMethodError("x.y").code == "unsupported")
    }

    @Test("The methods no guard list named before have explicit entries")
    func formerlyUnlistedMethodsAreExplicit() {
        let explicit: [BrowserReplDriverMethod] = [.tabInfo, .framesList, .frameOwnerBox, .downloadPath, .dialogRespond]
        for method in explicit {
            #expect(BrowserReplMethodSpec.spec(for: method.rawValue) != nil)
        }
        #expect(BrowserReplDriverMethod.dialogRespond.spec.frames == .dialogDocument)
        #expect(BrowserReplDriverMethod.tabsClose.spec.capability == .close)
    }

    @Test("Every driver event has a delivery, an event outside the table is dropped, and a path that does not match drops it")
    func everyEventHasASpec() {
        for event in BrowserReplDriverEvent.allCases {
            #expect(BrowserReplEventSpec.spec(for: event.rawValue) == event.spec, "\(event.rawValue)")
            #expect(event.isDelivered(through: event.spec.delivery.route), "\(event.rawValue)")
            // Exactly one path delivers each event.
            #expect(BrowserReplEventSpec.Route.allCases.filter(event.isDelivered(through:)) == [event.spec.delivery.route], "\(event.rawValue)")
            switch event.spec.delivery {
            case .everyAttached(let reason), .oneSession(let reason): #expect(!reason.isEmpty, "\(event.rawValue)")
            default: break
            }
        }
        #expect(BrowserReplEventSpec.spec(for: "permission.requested") == nil)
        // A page's console message sent to every attached session is dropped:
        // it must go through the path that judges its document.
        #expect(!BrowserReplDriverEvent.console.isDelivered(through: .everyAttached))
        #expect(!BrowserReplDriverEvent.dialogOpened.isDelivered(through: .everyAttached))
        #expect(!BrowserReplDriverEvent.downloadStarted.isDelivered(through: .everyAttached))
    }

    @Test("A load is judged by the domain policy")
    func loadsFollowThePolicy() throws {
        let authority = BrowserReplDocumentAuthority(sessionID: "s", policy: try policy(allowed: ["example.com"]), fileRoots: roots)
        #expect(authority.verdict(BrowserReplAccess(.load("https://example.com/a"))) == .allowed)
        let refused = authority.verdict(BrowserReplAccess(.load("https://evil.test/")))
        #expect(refused.refusal?.code == "blocked")
        #expect(refused.refusal?.message.hasPrefix("https://evil.test/ is blocked: ") == true)
    }

    @Test("A tab's page is judged by the file roots whatever the policy, then by the policy")
    func tabPagesFollowRootsAndPolicy() throws {
        let open = BrowserReplDocumentAuthority(sessionID: "s", fileRoots: roots)
        #expect(open.verdict(BrowserReplAccess(.tabPage("file:///etc/passwd"))).refusal?.code == "blocked")
        #expect(open.verdict(BrowserReplAccess(.tabPage("file:///tmp/session-work/a.html"))) == .allowed)
        #expect(open.verdict(BrowserReplAccess(.tabPage("https://evil.test/"))) == .allowed)
        let strict = BrowserReplDocumentAuthority(sessionID: "s", policy: try policy(prohibited: ["evil.test"]), fileRoots: roots)
        let refused = strict.verdict(BrowserReplAccess(.tabPage("https://evil.test/")))
        #expect(refused.refusal?.message.contains("which the domain policy blocks") == true)
        #expect(strict.verdict(BrowserReplAccess(.tabPage(""))) == .allowed)
    }

    @Test("A document is judged by the policy, its makers, and in another's tab off a web page by the file roots")
    func documentsJoinPolicyMakersAndRoots() throws {
        let authority = BrowserReplDocumentAuthority(sessionID: "s", policy: try policy(prohibited: ["evil.test"]), fileRoots: roots)
        let evil = BrowserReplFrameDocument(origin: "https://evil.test", place: "https://evil.test")
        #expect(authority.verdict(BrowserReplAccess(.document(evil))).reason != nil)
        // An opaque document a blocked page made is blocked.
        let made = BrowserReplFrameDocument(origin: "null", place: "data://", makers: [.page(evil)], opaque: "data:text/html,x")
        #expect(authority.verdict(BrowserReplAccess(.document(made))).reason?.contains("made by https://evil.test") == true)

        // Local documents, with no policy (a policy blocks every `file:` document).
        let local = BrowserReplDocumentAuthority(sessionID: "s", fileRoots: roots)
        let outside = BrowserReplFrameDocument(origin: "file://", place: "file://", local: "file:///etc/passwd")
        let userTab = BrowserReplTabFacts(mainFrameURL: URL(string: "file:///tmp/session-work/index.html"))
        let ownTab = BrowserReplTabFacts(mainFrameURL: URL(string: "file:///tmp/session-work/index.html"), creatorSessionID: "s")
        let webTab = BrowserReplTabFacts(mainFrameURL: URL(string: "https://example.com/"))
        #expect(local.judgesLocalDocuments(in: userTab))
        #expect(local.verdict(BrowserReplAccess(.document(outside), in: userTab)).reason != nil)
        // Its own tab keeps files out with content rules; a web page cannot frame one.
        #expect(local.verdict(BrowserReplAccess(.document(outside), in: ownTab)) == .allowed)
        #expect(local.verdict(BrowserReplAccess(.document(outside), in: webTab)) == .allowed)
        // Without a tab or without known roots, files are not judged.
        #expect(local.verdict(BrowserReplAccess(.document(outside))) == .allowed)
        let rootless = BrowserReplDocumentAuthority(sessionID: "s")
        #expect(rootless.verdict(BrowserReplAccess(.document(outside), in: userTab)) == .allowed)
        // An opaque document whose maker cmux cannot tell, in such a tab.
        let unknown = BrowserReplFrameDocument(origin: "null", place: "data://", makers: nil, opaque: "data:,x")
        #expect(local.verdict(BrowserReplAccess(.document(unknown), in: userTab)).reason != nil)
    }

    /// cmux serves local files to its browser through its own URL schemes
    /// (`cmux-diff-viewer:` streams the files a diff registered). A page of
    /// such a scheme is a local page the session's `fs` roots never
    /// granted: a user's tab that shows one, a frame of one, a document it
    /// made and a document of its origin are refused as a local file
    /// outside the session's directories is, whatever the policy.
    @Test("A page cmux serves through its own URL scheme is judged as a local file outside the session's directories")
    func appServedPagesAreLocalFilesOutsideTheRoots() throws {
        let local = BrowserReplDocumentAuthority(sessionID: "s", fileRoots: roots)
        let address = "cmux-diff-viewer://0123456789abcdef0123456789abcdef/index.html"
        let userTab = BrowserReplTabFacts(mainFrameURL: URL(string: address))
        #expect(local.judgesLocalDocuments(in: userTab))
        let viewer = BrowserReplFrameDocument(url: URL(string: address))
        #expect(local.verdict(BrowserReplAccess(.document(viewer), in: userTab)).refusal?.code == "blocked",
                "a user's tab on cmux's own scheme was readable")
        // The same document recorded by WebKit for a frame (its origin is the scheme's).
        let framed = BrowserReplFrameDocument(origin: "cmux-diff-viewer://0123456789abcdef0123456789abcdef", place: "cmux-diff-viewer://0123456789abcdef0123456789abcdef")
        #expect(local.verdict(BrowserReplAccess(.document(framed), in: userTab)).reason != nil)
        // An about:blank of its origin, and a data: document it made.
        let inherited = BrowserReplFrameDocument(origin: "cmux-diff-viewer://0123456789abcdef0123456789abcdef", place: "about://")
        #expect(local.verdict(BrowserReplAccess(.document(inherited), in: userTab)).reason != nil)
        let made = BrowserReplFrameDocument(origin: "null", place: "data://", makers: [.page(framed)], opaque: "data:text/html,x")
        #expect(local.verdict(BrowserReplAccess(.document(made), in: userTab)).reason != nil)
        // The tab's page and a load of it, as for a file outside the roots.
        #expect(local.verdict(BrowserReplAccess(.tabPage(address), in: userTab)).refusal?.code == "blocked")
        #expect(local.verdict(BrowserReplAccess(.load(address))).refusal?.code == "blocked")
        #expect(local.landedPage(address, in: userTab).refusal != nil)
        // Web pages stay readable.
        let web = BrowserReplFrameDocument(origin: "https://example.com", place: "https://example.com")
        #expect(local.verdict(BrowserReplAccess(.document(web), in: userTab)) == .allowed)
        #expect(local.verdict(BrowserReplAccess(.tabPage("https://example.com/"), in: userTab)) == .allowed)
    }

    @Test("Another live session's tab is denied")
    func otherSessionsTabIsDenied() {
        let authority = BrowserReplDocumentAuthority(sessionID: "s")
        let theirs = BrowserReplTabFacts(id: UUID(), creatorSessionID: "other", attachedSessionIDs: ["other"])
        for capability in BrowserReplTabCapability.allCases {
            let verdict = authority.verdict(BrowserReplAccess(in: theirs, capability: capability))
            #expect(verdict.refusal?.code == "denied")
        }
        let mine = BrowserReplTabFacts(id: UUID(), creatorSessionID: "s", attachedSessionIDs: ["s"])
        #expect(authority.verdict(BrowserReplAccess(in: mine, capability: .use)) == .allowed)
        #expect(authority.verdict(BrowserReplAccess(in: mine, capability: .close)) == .allowed)
    }

    @Test("A session uses tabs of its own workspace only: another workspace's tab needs a person's grant")
    func crossWorkspaceReachIsDenied() {
        let own = UUID()
        let elsewhere = UUID()
        let authority = BrowserReplDocumentAuthority(sessionID: "s", workspaceID: own)
        let userTabHere = BrowserReplTabFacts(id: UUID(), workspaceID: own)
        let userTabElsewhere = BrowserReplTabFacts(id: UUID(), attachedSessionIDs: ["s"], workspaceID: elsewhere)
        #expect(authority.verdict(BrowserReplAccess(in: userTabHere, capability: .use)) == .allowed)
        for capability in BrowserReplTabCapability.allCases {
            let verdict = authority.verdict(BrowserReplAccess(in: userTabElsewhere, capability: capability))
            #expect(verdict.refusal?.code == "denied", "\(capability)")
            #expect(verdict.refusal?.message.contains("another workspace") == true, "\(capability)")
        }
        // Its own popup in another workspace (a tab it created) stays usable.
        let ownTabElsewhere = BrowserReplTabFacts(id: UUID(), creatorSessionID: "s", attachedSessionIDs: ["s"], workspaceID: elsewhere)
        #expect(authority.verdict(BrowserReplAccess(in: ownTabElsewhere, capability: .use)) == .allowed)
        // A tab whose workspace cannot be told is not reachable either.
        let unplaced = BrowserReplTabFacts(id: UUID(), workspaceID: nil)
        #expect(authority.verdict(BrowserReplAccess(in: unplaced, capability: .use)).refusal?.code == "denied")
    }

    @Test("A session never closes a user's tab it is not attached to")
    func closingAnUnattachedUserTabIsDenied() {
        let own = UUID()
        let authority = BrowserReplDocumentAuthority(sessionID: "s", workspaceID: own)
        let unattached = BrowserReplTabFacts(id: UUID(), attachedSessionIDs: ["other"], workspaceID: own)
        let closing = authority.verdict(BrowserReplAccess(in: unattached, capability: .close))
        #expect(closing.refusal?.code == "denied")
        #expect(authority.verdict(BrowserReplAccess(in: unattached, capability: .use)) == .allowed)
        let attached = BrowserReplTabFacts(id: UUID(), attachedSessionIDs: ["s"], workspaceID: own)
        #expect(authority.verdict(BrowserReplAccess(in: attached, capability: .close)) == .allowed)
        let created = BrowserReplTabFacts(id: UUID(), creatorSessionID: "s", attachedSessionIDs: ["s"], workspaceID: own)
        #expect(authority.verdict(BrowserReplAccess(in: created, capability: .close)) == .allowed)
    }

    @Test("tabs.list shows a session only its own workspace's tabs and names a data store only of a tab it may use")
    func listingFollowsTheWorkspace() {
        let own = UUID()
        let elsewhere = UUID()
        let authority = BrowserReplDocumentAuthority(sessionID: "s", workspaceID: own)
        #expect(authority.listing(of: BrowserReplTabFacts(id: UUID(), workspaceID: own)) == .usable)
        #expect(authority.listing(of: BrowserReplTabFacts(id: UUID(), creatorSessionID: "s", workspaceID: elsewhere)) == .usable)
        // A user's tab of another workspace, its private profile store with it, is not listed.
        #expect(authority.listing(of: BrowserReplTabFacts(id: UUID(), workspaceID: elsewhere)) == .hidden)
        #expect(authority.listing(of: BrowserReplTabFacts(id: UUID(), workspaceID: nil)) == .hidden)
        // Another session's tab: named in the session's workspace, hidden in another.
        let theirs = BrowserReplTabFacts(id: UUID(), creatorSessionID: "other", attachedSessionIDs: ["other"], workspaceID: own)
        #expect(authority.listing(of: theirs) == .ownedByAnotherSession("other"))
        var theirsElsewhere = theirs
        theirsElsewhere.workspaceID = elsewhere
        #expect(authority.listing(of: theirsElsewhere) == .hidden)
    }

    @Test("tabs.open({ dataStore }) takes a store only from a tab the session may use")
    func dataStoreFollowsTheTabCapability() {
        let own = UUID()
        let elsewhere = UUID()
        let authority = BrowserReplDocumentAuthority(sessionID: "s", workspaceID: own)
        let profile = BrowserReplDataStoreCandidate(tab: BrowserReplTabFacts(id: UUID(), workspaceID: elsewhere), storeID: "private", store: "other workspace's profile")
        #expect(authority.dataStore("private", among: [profile]) == nil, "another workspace's private store was taken")
        let theirs = BrowserReplDataStoreCandidate(
            tab: BrowserReplTabFacts(id: UUID(), creatorSessionID: "other", attachedSessionIDs: ["other"], workspaceID: own),
            storeID: "proxy", store: "other session's store"
        )
        #expect(authority.dataStore("proxy", among: [theirs]) == nil)
        let userHere = BrowserReplDataStoreCandidate(tab: BrowserReplTabFacts(id: UUID(), workspaceID: own), storeID: "private", store: "this workspace's store")
        #expect(authority.dataStore("private", among: [profile, userHere]) == "this workspace's store")
        let mineElsewhere = BrowserReplDataStoreCandidate(
            tab: BrowserReplTabFacts(id: UUID(), creatorSessionID: "s", attachedSessionIDs: ["s"], workspaceID: elsewhere),
            storeID: "mine", store: "own popup's store"
        )
        #expect(authority.dataStore("mine", among: [mineElsewhere]) == "own popup's store")
    }

    @Test("Every method that leaves the page judges the page it lands on, as a tab page")
    func landedPagesAreJudged() throws {
        for method in [BrowserReplDriverMethod.tabNavigate, .tabHistory, .tabReload] {
            #expect(method.spec.judgesLandedPage, "\(method.rawValue) does not judge the page it lands on")
        }
        #expect(!BrowserReplDriverMethod.tabInfo.spec.judgesLandedPage)
        // A user's tab that history or a reload took to a local file outside
        // the session's directories, with no domain policy at all.
        let authority = BrowserReplDocumentAuthority(sessionID: "s", fileRoots: roots)
        let userTab = BrowserReplTabFacts(mainFrameURL: URL(string: "file:///etc/passwd"))
        let landed = authority.landedPage("file:///etc/passwd", in: userTab)
        #expect(landed.refusal?.code == "blocked")
        #expect(landed.refusal?.message.contains("the tab is the user's") == true)
        #expect(authority.landedPage("file:///tmp/session-work/a.html", in: userTab) == .allowed)
        let strict = BrowserReplDocumentAuthority(sessionID: "s", policy: try policy(prohibited: ["evil.test"]), fileRoots: roots)
        #expect(strict.landedPage("https://evil.test/", in: BrowserReplTabFacts()).refusal?.code == "blocked")
    }

    @Test("The policy board's authority carries the session's policy and directories")
    func boardAuthority() throws {
        let board = BrowserReplPolicyBoard()
        board.publish(try policy(prohibited: ["evil.test"]), sessionID: "s")
        board.setFileRoots(roots, sessionID: "s")
        let authority = board.authority(for: "s")
        #expect(authority.fileRoots == roots)
        #expect(authority.verdict(BrowserReplAccess(.load("https://evil.test/"))).reason != nil)
        #expect(board.authority(for: "unknown").verdict(BrowserReplAccess(.load("https://evil.test/"))) == .allowed)
    }
    /// r17 whole#3: a `cwd` change publishes new directories, but a tab the
    /// session created skips the local-document check on reads, so its old
    /// page of a local file's origin must not stay live: on a root change
    /// every such page is judged against the new directories, reloaded when
    /// it lies inside them and made `about:blank` otherwise; web pages and
    /// user tabs stay.
    @Test("A cwd change replaces the session's local pages outside the new directories")
    func rootChangeReplacesOldLocalPages() throws {
        let session = "s1"
        let before = BrowserReplDocumentAuthority(sessionID: session, fileRoots: ["/tmp/old-work", "/tmp/session-tmp"])
        let after = BrowserReplDocumentAuthority(sessionID: session, fileRoots: ["/tmp/new-work", "/tmp/session-tmp"])
        func tab(_ url: String, creator: String? = session) -> BrowserReplTabFacts {
            BrowserReplTabFacts(id: UUID(), mainFrameURL: URL(string: url), creatorSessionID: creator)
        }
        func isBlank(_ r: BrowserReplPageReplacement) -> Bool { if case .blank = r { return true }; return false }
        func isReload(_ r: BrowserReplPageReplacement) -> Bool { if case .reload = r { return true }; return false }

        // An old-root file page, and a document that may hold its origin.
        #expect(isBlank(after.pageReplacement(after: before, in: tab("file:///tmp/old-work/index.html"))))
        #expect(isBlank(after.pageReplacement(after: before, in: tab("about:blank"))))
        // A file inside the new directories loads again (its old frames go).
        #expect(isReload(after.pageReplacement(after: before, in: tab("file:///tmp/new-work/index.html"))))
        // The reason reaches the tab's sessions.
        if case .blank(let reason) = after.pageReplacement(after: before, in: tab("file:///tmp/old-work/index.html")) {
            #expect(reason.contains("working directory"), "\(reason)")
        }
        // Web pages, user tabs and an unchanged root set stay.
        #expect(after.pageReplacement(after: before, in: tab("https://example.com/")) == .keep)
        #expect(after.pageReplacement(after: before, in: tab("file:///tmp/old-work/index.html", creator: nil)) == .keep)
        #expect(after.pageReplacement(after: after, in: tab("file:///tmp/new-work/index.html")) == .keep)
        // Adding a directory takes nothing away.
        let wider = BrowserReplDocumentAuthority(sessionID: session, fileRoots: ["/tmp/old-work", "/tmp/session-tmp", "/tmp/more"])
        #expect(wider.pageReplacement(after: before, in: tab("file:///tmp/old-work/index.html")) == .keep)
        // A narrowing policy still reloads web pages it allows and blanks the rest.
        let narrowed = BrowserReplDocumentAuthority(sessionID: session, policy: try policy(allowed: ["example.com"]), fileRoots: before.fileRoots)
        #expect(isReload(narrowed.pageReplacement(after: before, in: tab("https://example.com/"))))
        #expect(isBlank(narrowed.pageReplacement(after: before, in: tab("https://other.test/"))))
    }
}
