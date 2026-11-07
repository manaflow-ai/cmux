import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome
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
        let value = HomeMessagesHostProvider.json(hidden: [HomeChiefRosterTests.ada: 42])
        #expect(value == .object(["hidden": .object(["conv_ada": .number(42)])]))
        #expect(HomeMessagesHostProvider.json(hidden: [:]) == .object(["hidden": .object([:])]))
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
        let host = HomeMessagesHostProvider(services: services)
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
        drafts.save([part], migrated: [], for: id)
        let loaded = await drafts.load()
        #expect(loaded.value(at: ["attachments", id.rawValue]) == .array([part]))
        let legacy = try #require(loaded.value(at: ["legacy", id.rawValue])?.arrayValue?.first)
        #expect(legacy.value(at: ["hash"])?.stringValue == native.ref.hash)
        #expect(legacy.value(at: ["data"])?.stringValue == Data("notes".utf8).base64EncodedString())
        // A save that names another hash lets go of nothing; naming it lets go of it.
        drafts.save([part], migrated: ["other"], for: id)
        #expect(store.draftAttachments(for: id) == [native])
        drafts.save([part], migrated: [native.ref.hash], for: id)
        #expect(store.draftAttachments(for: id).isEmpty)
        drafts.save([], migrated: [], for: id)
        #expect(store.uploadedDraftAttachments(for: id) == nil)
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

    /// Round 4 F2: the page's unsent sends are kept in HomeStore's draft cache per conversation.
    @Test func unsentSendsAreKeptPerConversation() throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let outbox = HomeMessagesOutbox(store: store)
        let row = JSONValue.object(["key": .string("k1"), "conversation": .string("conv_ada"), "text": .string("hi"),
                                    "createdAt": .number(1), "failed": .bool(true)])
        try outbox.save([row], for: HomeChiefRosterTests.ada)
        #expect(outbox.load() == .object(["pending": .object(["conv_ada": .array([row])])]))
        try outbox.save([], for: HomeChiefRosterTests.ada)
        #expect(outbox.load() == .object(["pending": .object([:])]))
        #expect(throws: HomeMessagesOutbox.Refusal.tooMany) {
            try outbox.save(Array(repeating: row, count: HomeMessagesOutbox.maxRows + 1), for: HomeChiefRosterTests.ada)
        }
    }

    /// Round 4 F4: an empty Chief chat's Open Terminal and Start Agent run the registry's actions the
    /// native first run ran, on the person's click only.
    @Test func firstRunActionsRunTheRegistrysActions() async throws {
        let services = HomeChiefDefaultTests.services()
        Self.kept.append(services)
        var ran: [String] = []
        _ = services.registry.bind(HomeMessagesFirstRunProvider.openTerminalAction, invoke: { _ in ran.append("terminal") })
        _ = services.registry.bind(HomeMessagesFirstRunProvider.startAgentAction, invoke: { _ in ran.append("agent") })
        let provider = HomeMessagesFirstRunProvider(services: services, shown: { nil })
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
