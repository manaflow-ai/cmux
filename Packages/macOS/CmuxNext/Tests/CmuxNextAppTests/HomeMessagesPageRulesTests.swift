import AppKit
@testable import CmuxNextApp
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextPages
import CmuxNextSettings
import Foundation
import ImageIO
import Testing

/// What the React Messages page's host decides (review of cmux#37736 at c3dd70eb): New Message
/// stays open while the page reports no conversation (F1), the first load opens the preferred
/// Chief by the same rule as later ones (C1), Delete Conversation from List moves the page off the
/// deleted conversation (F4), and the page view is found by the focus model (F5).
@MainActor @Suite(.serialized)
struct HomeMessagesPageRulesTests {
    /// F1: New Message reports `conversation: null` with `composing`; the default conversation must
    /// not open over it (it would leave New Message at once).
    @Test func newMessageIsNeverReplacedByTheDefaultConversation() {
        let home = Self.home()
        let rows = HomeChiefDefaultTests.cloudLedRows
        let composing = HomeDefaultConversation.afterShown(nil, composing: true, followed: "conv_hosted", rows: rows, home: home)
        #expect(composing == .init(open: nil, followed: "conv_hosted"), "New Message stays, and what was followed stays followed")
        let empty = HomeDefaultConversation.afterShown(nil, composing: false, followed: nil, rows: rows, home: home)
        #expect(empty.open?.rawValue == "conv_hosted", "nothing shown and no New Message: the default opens, so the test above fails for its own reason")
    }

    /// C1: the first report (nothing open once the inbox is read) opens the preferred Chief and
    /// follows it, as a later Chief change would; a conversation the person opened stays theirs.
    @Test func theFirstLoadOpensThePreferredChiefAndFollowsIt() {
        let home = Self.home()
        let rows = HomeChiefDefaultTests.cloudLedRows
        let first = HomeDefaultConversation.afterShown(nil, composing: false, followed: nil, rows: rows, home: home)
        #expect(first == .init(open: CmuxHomeCore.ConversationID("conv_hosted"), followed: "conv_hosted"))
        // The page then reports the Chief it opened: still followed.
        #expect(HomeDefaultConversation.afterShown(CmuxHomeCore.ConversationID("conv_hosted"), composing: false, followed: first.followed,
                                                   rows: rows, home: home) == .init(open: nil, followed: "conv_hosted"))
        // The person opens a DM: no longer followed, and nothing opens.
        #expect(HomeDefaultConversation.afterShown(HomeChiefRosterTests.ada, composing: false, followed: "conv_hosted",
                                                   rows: rows, home: home) == .init(open: nil, followed: nil))
    }

    /// F4: leaving the shown conversation shows its neighbor, else the default conversation.
    @Test func deletingTheShownConversationMovesToItsNeighborElseTheDefault() {
        let home = Self.home()
        let rows = HomeChiefDefaultTests.cloudLedRows
        let local = HomeChiefRosterTests.local
        #expect(HomeDefaultConversation.replacement(leaving: HomeChiefRosterTests.ada, next: local, rows: rows, home: home) == local)
        #expect(HomeDefaultConversation.replacement(leaving: HomeChiefRosterTests.ada, next: nil, rows: rows, home: home)?.rawValue == "conv_hosted")
        #expect(HomeDefaultConversation.replacement(leaving: HomeChiefRosterTests.ada, next: HomeChiefRosterTests.ada, rows: rows, home: home)?.rawValue
            == "conv_hosted", "the conversation itself is no neighbor")
    }

    /// F4: the deleted set goes to the page as `{hidden: {id: seq}}`.
    @Test func theHiddenStreamSendsEachDeletedConversationWithItsSeq() {
        let value = HomeMessagesHiddenFeed.json(hidden: [HomeChiefRosterTests.ada: 42])
        #expect(value == .object(["hidden": .object(["conv_ada": .number(42)]), "archived": .array([])]))
        #expect(HomeMessagesHiddenFeed.json(hidden: [:]) == .object(["hidden": .object([:]), "archived": .array([])]))
    }

    /// Round 5 F3: a Chief archived on this Mac leaves the page's list: its conversation goes in the
    /// hidden stream's `archived`, as the native list filtered it.
    @Test func anArchivedChiefsConversationGoesToThePageAsArchived() throws {
        let rows = HomeChiefDefaultTests.cloudLedRows
        let chief = try #require(rows.first { $0.kind == .chief })
        let agent = try #require(chief.summary.participants.first { $0.agentClass == .chief })
        let archived = HomeArchivedChiefs([agent.id.rawValue], me: nil).hiddenConversations(rows)
        #expect(archived.contains(chief.id))
        #expect(!archived.contains { id in rows.first { $0.id == id }?.kind != .chief })
        #expect(HomeArchivedChiefs([], me: nil).hiddenConversations(rows).isEmpty)
        let value = HomeMessagesHiddenFeed.json(hidden: [:], archived: [chief.id])
        #expect(value.value(at: ["archived"]) == .array([.string(chief.id.rawValue)]))
        // The page hears the archive once; a rows update that leaves the set alone sends nothing.
        let feed = HomeMessagesHiddenFeed()
        var shown: [Bool] = []
        feed.archived = { shown.count > 0 ? [chief.id] : [] }
        var heard: [JSONValue] = []
        feed.subscribe(UUID()) { heard.append($0); shown.append(true) }
        feed.publish()
        feed.publish()
        #expect(heard.map { $0.value(at: ["archived"]) } == [.array([]), .array([.string(chief.id.rawValue)])])
    }

    /// F5: a Home pane tab's content is this view; the focus model finds its page through
    /// ``PageWebViewContainer`` (``PageWebView/shown(in:)``), else the tab focuses a wrapper that takes no keys.
    @Test func theMessagesPageNamesItsPageToTheFocusModel() {
        #expect((HomeMessagesPage.self as Any) is any PageWebViewContainer.Type)
    }

    /// Round 2 F3: New Message keeps the conversation open before it as the host's `shown`, so the
    /// dock's Messages to Channels switch (its fallback reads `shown`) hands that conversation on.
    @Test func newMessageKeepsTheConversationOpenBeforeIt() {
        let services = HomeChiefDefaultTests.services()
        Self.kept.append(services)
        let host = HomeMessagesHostProvider(services: services, widthKey: "test")
        var heard: [(CmuxHomeCore.ConversationID?, Bool)] = []
        host.onShown = { heard.append(($0, $1)) }
        host.reportShown(HomeChiefRosterTests.ada, composing: false)
        host.reportShown(nil, composing: true)
        #expect(host.shown == HomeChiefRosterTests.ada, "New Message is not 'nothing open'")
        #expect(host.page.composing)
        #expect(heard.last.map { $0.0 == HomeChiefRosterTests.ada && $0.1 } == true)
        host.reportShown(nil, composing: false)
        #expect(host.shown == nil, "New Message closed with nothing open: nothing is shown")
        #expect(!host.page.composing)
    }

    /// Round 2 F2: the drag strip takes the app's one titlebar path: it answers `.movesWindow` to
    /// ``TitlebarDragPolicy`` and its own mouse-down moves nothing (the window's `sendEvent` drags once).
    @Test func theDragStripLeavesTheDragToTheWindowsTitlebarPath() throws {
        let strip = HomeWindowDragStrip(frame: CGRect(x: 0, y: 0, width: 200, height: HomeWindowDragStrip.height))
        #expect(strip.titlebarPress(atWindowPoint: .zero) == .movesWindow)
        #expect(strip.mouseDownCanMoveWindow)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(strip)
        let before = window.frame
        let press = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 95), modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        strip.mouseDown(with: press)
        #expect(window.frame == before, "a double-click on the strip itself zooms nothing: the window's path runs it once")
    }

    /// Round 3 F5: a host-to-page call is asked again only while the page cannot take it (no handler
    /// yet, or no link); a page that took it and refused is not asked again, so one Ctrl-Tab moves once.
    @Test func onlyAPageThatIsNotReadyIsAskedAgain() {
        #expect(HomePageAskAttempt(PageError.unknownOp("cmux.home.moveConversation")) == .notReady)
        #expect(HomePageAskAttempt(PageError.closed) == .notReady)
        #expect(HomePageAskAttempt(PageError.invalidParams("no such conversation")) == .refused)
        #expect(HomePageAskAttempt(CancellationError()) == .refused)
    }

    /// Round 3 F3: the page's staged attachments go to HomeStore's draft cache and come back; the
    /// native composer's go to the page with their bytes once, and leave HomeStore only when the
    /// page names them as taken.
    @Test func stagedAttachmentsAreKeptAndTheNativeOnesHandedOver() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-messages-attachments-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root)
        store.start()
        defer { store.stop() }
        let id = HomeChiefRosterTests.ada
        let native = try await store.prepareAttachment(data: Data("notes".utf8), typeIdentifier: "public.plain-text")
        store.setDraftAttachments([native], for: id)
        let drafts = HomeMessagesAttachmentDrafts(store: store)
        let part = JSONValue.object(["type": .string("attachment"), "hash": .string("h1"), "name": .string("a.png"),
                                     "mimeType": .string("image/png"), "byteCount": .number(3)])
        let other = JSONValue.object(["type": .string("attachment"), "hash": .string("h0"), "name": .string("b.png"),
                                      "mimeType": .string("image/png"), "byteCount": .number(4)])
        // Round 5 F1: two pages each keep their own part; neither overwrites the other's, and the
        // tray comes back in the order they were attached.
        try HomeMessagesAttachmentDrafts(store: store).put(part, at: 2, for: id)
        try drafts.put(other, at: 1, for: id)
        let loaded = await drafts.load()
        #expect(loaded.value(at: ["attachments", id.rawValue]) == .array([other, part]))
        let legacy = try #require(loaded.value(at: ["legacy", id.rawValue])?.arrayValue?.first)
        #expect(legacy.value(at: ["hash"])?.stringValue == native.ref.hash)
        #expect(legacy.value(at: ["data"])?.stringValue == Data("notes".utf8).base64EncodedString())
        // Releasing another hash lets go of nothing; naming it lets go of it.
        drafts.release(["other"], for: id)
        #expect(store.draftAttachments(for: id) == [native])
        drafts.release([native.ref.hash], for: id)
        #expect(store.draftAttachments(for: id).isEmpty)
        drafts.remove("h0", for: id)
        #expect(await drafts.load().value(at: ["attachments", id.rawValue]) == .array([part]))
        drafts.remove("h1", for: id)
        #expect(store.uploadedDraftAttachments(for: id).isEmpty)
        #expect(throws: HomeMessagesAttachmentDrafts.Refusal.noHash) { try drafts.put(.object([:]), at: 0, for: id) }
    }

    /// Round 4 F1: a photo the page attaches goes through the host's preparation, which removes its
    /// GPS unless Settings > Home keeps location (as the native composer's prepareAttachment did).
    @Test func aPhotosLocationIsRemovedBeforeItUploads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-messages-prepare-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appending(path: "blobs"))
        store.start()
        defer { store.stop() }
        let jpeg = try Self.jpegWithGPS()
        #expect(Self.hasGPS(jpeg), "the fixture carries GPS, so the test below fails for its own reason")
        var keep = false
        let preparer = HomeAttachmentPreparer(store: store, keepLocation: { keep }, directory: root.appending(path: "prepare"))
        let begun = try await preparer.call("begin", ["name": .string("photo.jpg"), "mimeType": .string("image/jpeg"),
                                                      "byteCount": .number(Double(jpeg.count))])
        let id = try #require(begun.value(at: ["id"])?.stringValue)
        _ = try await preparer.call("chunk", ["id": .string(id), "offset": .number(0), "data": .string(jpeg.base64EncodedString())])
        let done = try await preparer.call("finish", ["id": .string(id)])
        #expect(done.value(at: ["changed"]) == .bool(true))
        let count = try #require(done.value(at: ["byteCount"])?.doubleValue)
        let read = try await preparer.call("read", ["id": .string(id), "offset": .number(0), "length": .number(count)])
        let out = try #require(read.value(at: ["data"])?.stringValue.flatMap { Data(base64Encoded: $0) })
        #expect(out.count == Int(count))
        #expect(!Self.hasGPS(out), "the uploaded photo has no location")
        _ = try await preparer.call("end", ["id": .string(id)])
        keep = true
        let kept = try await preparer.call("begin", ["name": .string("photo.jpg"), "mimeType": .string("image/jpeg"),
                                                     "byteCount": .number(Double(jpeg.count))])
        #expect(kept == .object(["keep": .bool(true)]), "Keep Location in Photos: the original goes")
    }

    /// Round 4 F2 and round 5 F1/F4: the page's unsent sends are kept in HomeStore's draft cache,
    /// one entry per send key, so one page's delivered send never drops another page's failed one;
    /// a send past the entry cap is refused with the code the page shows as not kept.
    @Test func unsentSendsAreKeptPerSend() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let pageA = HomeMessagesOutbox(store: store)
        let pageB = HomeMessagesOutbox(store: store)
        let failed = JSONValue.object(["key": .string("k1"), "conversation": .string("conv_ada"), "text": .string("hi"),
                                       "createdAt": .number(1), "failed": .bool(true)])
        let sent = JSONValue.object(["key": .string("k2"), "conversation": .string("conv_ada"), "text": .string("there"),
                                     "createdAt": .number(2), "failed": .bool(false)])
        try pageA.put(failed, for: HomeChiefRosterTests.ada)
        try pageB.put(sent, for: HomeChiefRosterTests.ada)
        #expect(pageA.load() == .object(["pending": .object(["conv_ada": .array([failed, sent])])]))
        pageB.remove("k2", for: HomeChiefRosterTests.ada)
        #expect(pageB.load() == .object(["pending": .object(["conv_ada": .array([failed])])]))
        pageA.remove("k1", for: HomeChiefRosterTests.ada)
        #expect(pageA.load() == .object(["pending": .object([:])]))
        #expect(throws: HomeMessagesOutbox.Refusal.noKey) { try pageA.put(.object([:]), for: HomeChiefRosterTests.ada) }
        let kept = HomeMessagesKept(store: store, keepLocation: { false })
        let huge = JSONValue.object(["key": .string("k3"), "conversation": .string("conv_ada"),
                                     "text": .string(String(repeating: "x", count: HomeMessagesOutbox.maxEntryBytes + 1)),
                                     "createdAt": .number(3), "failed": .bool(false)])
        await #expect(throws: PageError(code: HomeMessagesKept.tooLargeCode, message: "the send is larger than the outbox keeps")) {
            _ = try await kept.call("outbox.put", ["conversation": .string("conv_ada"), "send": huge])
        }
        #expect(pageA.load() == .object(["pending": .object([:])]))
    }

    /// Round 4 F4: an empty Chief chat's Open Terminal and Start Agent run the registry's actions the
    /// native first run ran, on the person's click only.
    @Test func firstRunActionsRunTheRegistrysActions() async throws {
        let services = HomeChiefDefaultTests.services()
        Self.kept.append(services)
        var ran: [String] = []
        _ = services.registry.bind(ActionID(rawValue: HomeMessagesFirstRunProvider.openTerminalAction), invoke: { _ in ran.append("terminal") })
        _ = services.registry.bind(ActionID(rawValue: HomeMessagesFirstRunProvider.startAgentAction), invoke: { _ in ran.append("agent") })
        let provider = HomeMessagesFirstRunProvider(sources: PageFactory.firstRunSources(services), shown: { nil })
        let click = PageCallContext(page: PageDescriptor.homeMessages.id, userGesture: true)
        let op = HomeMessagesFirstRunProvider.prefix + ".action"
        _ = try await provider.call(op, params: .object(["action": .string("openTerminal")]), context: click)
        _ = try await provider.call(op, params: .object(["action": .string("startAgent")]), context: click)
        #expect(ran == ["terminal", "agent"])
        await #expect(throws: PageError.self) {
            try await provider.call(op, params: .object(["action": .string("openTerminal")]),
                                    context: PageCallContext(page: PageDescriptor.homeMessages.id))
        }
        #expect(ran == ["terminal", "agent"], "a page's own call runs nothing")
    }

    /// Round 9 (5): a request's Block and removing a group member need the person's own click, as a create, an
    /// invite and a link out do; Accept, Decline and the reads do not.
    @Test func blockingARequestAndRemovingAMemberNeedThePerson() {
        #expect(HomeMessagesPageRoute.needsPerson("requests.answer", ["answer": "block"]))
        #expect(HomeMessagesPageRoute.needsPerson("group.remove", ["participant": "ana"]))
        for name in ["chief.create", "invite.send", "teamInvite.send", "openLink", "headerPanels.toggle"] {
            #expect(HomeMessagesPageRoute.needsPerson(name, [:]), "\(name)")
        }
        #expect(!HomeMessagesPageRoute.needsPerson("requests.answer", ["answer": "accept"]))
        #expect(!HomeMessagesPageRoute.needsPerson("requests.answer", ["answer": "decline"]))
        #expect(!HomeMessagesPageRoute.needsPerson("group.info", [:]))
        #expect(!HomeMessagesPageRoute.needsPerson("requests.list", [:]))
    }

    static func jpegWithGPS() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"]
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func hasGPS(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    /// The suite's services: `HomeService` holds its services unowned, so they live for the run.
    static var kept: [AppServices] = []

    /// Auto with no local brain and a Hosted Chief: the Hosted Chief is the preferred one.
    static func home() -> HomeService {
        let services = HomeChiefDefaultTests.services()
        kept.append(services)
        services.home.setCloudChiefs(HomeCloudChiefs(hosted: HomeChiefDefaultTests.hosted, placed: HomeChiefDefaultTests.placed))
        services.home.localChiefRunning = false
        return services.home
    }
}
