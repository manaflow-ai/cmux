// TabCardSnapshots is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

/// Every tab's card has a last-known picture that outlives the launch (Leo, 2026-11-22: "and
/// why do we not have cached previews of the other tabs", "i either dont see anything aka
/// blank placeholders or i see fucking layout shifts??? from previews of othet tabs??  why are
/// they moving???"). Before, an agent card's picture lived in memory only and a card without
/// one laid out a live page of transcript; a browser card had a snapshot only for a page shown
/// in this launch.
@MainActor @Suite(.serialized) struct TabCardSnapshotTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tab-snapshots-\(UUID().uuidString)", isDirectory: true)
    }

    static func key(_ tab: String, account: String = "user-1") -> TabSnapshotKey {
        TabSnapshotKey(accountID: account, macID: "mac-1", tabID: tab)
    }

    static func picture(_ color: UIColor, width: CGFloat = 40, height: CGFloat = 56) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func wait(_ what: String, until done: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(done(), "\(what) within 5 s")
    }

    @Test func aPictureIsStoredOnceByItsHashAndReadBack() {
        let store = TabSnapshotStore(directory: Self.directory())
        let bytes = Data("picture".utf8)
        store.save(bytes, pixelWidth: 4, pixelHeight: 6, capturedAtMs: 10, source: .phone, for: Self.key("a"))
        store.save(bytes, pixelWidth: 4, pixelHeight: 6, capturedAtMs: 11, source: .mac, for: Self.key("b"))
        #expect(store.picture(Self.key("a")) == bytes)
        #expect(store.record(Self.key("b"))?.source == .mac)
        #expect(store.record(Self.key("a"))?.thumbHash == TabSnapshotStore.hash(bytes))
        let blobs = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path))?.filter { $0.hasPrefix("blob-") }
        #expect(blobs?.count == 1, "two tabs with the same picture share one blob")
    }

    @Test func aNewerCaptureWinsAndAnOlderOneIsRefused() {
        let store = TabSnapshotStore(directory: Self.directory())
        let old = Data("old".utf8), new = Data("new".utf8)
        store.save(new, pixelWidth: 1, pixelHeight: 1, capturedAtMs: 20, source: .mac, for: Self.key("a"))
        store.save(old, pixelWidth: 1, pixelHeight: 1, capturedAtMs: 10, source: .phone, for: Self.key("a"))
        #expect(store.picture(Self.key("a")) == new)
        store.save(old, pixelWidth: 1, pixelHeight: 1, capturedAtMs: 30, source: .phone, for: Self.key("a"))
        #expect(store.picture(Self.key("a")) == old)
        #expect(!store.hasBlob(TabSnapshotStore.hash(new)), "a blob no record names is removed")
    }

    @Test func aClosedTabsPictureGoesAndASharedBlobStays() {
        let store = TabSnapshotStore(directory: Self.directory())
        let bytes = Data("shared".utf8)
        store.save(bytes, pixelWidth: 1, pixelHeight: 1, capturedAtMs: 1, source: .phone, for: Self.key("a"))
        store.save(bytes, pixelWidth: 1, pixelHeight: 1, capturedAtMs: 1, source: .phone, for: Self.key("b"))
        store.remove(Self.key("a"))
        #expect(store.picture(Self.key("a")) == nil)
        #expect(store.picture(Self.key("b")) == bytes)
        store.remove(Self.key("b"))
        #expect(!store.hasBlob(TabSnapshotStore.hash(bytes)))
    }

    @Test func anotherAccountNeverReadsThisAccountsPicture() {
        let store = TabSnapshotStore(directory: Self.directory())
        store.save(Data("mine".utf8), pixelWidth: 1, pixelHeight: 1, capturedAtMs: 1, source: .phone, for: Self.key("a"))
        #expect(store.picture(Self.key("a", account: "user-2")) == nil)
        // Parts are encoded one by one: "a-b" + "c" and "a" + "b-c" are different files.
        let one = TabSnapshotKey(accountID: "a-b", macID: "c", tabID: "t"), two = TabSnapshotKey(accountID: "a", macID: "b-c", tabID: "t")
        #expect(one.fileComponent != two.fileComponent)
        let snapshots = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        #expect(snapshots.key(macID: "mac-1", tabID: "a") == nil, "signed out: no key, nothing read or written")
        snapshots.accountID = { "user-1" }
        #expect(snapshots.key(macID: "mac-1", tabID: "a") == Self.key("a"))
    }

    /// The launch after: a picture put in one launch is on the card in the next, before any chat or page loads.
    @Test func aPicturePutInOneLaunchIsShownInTheNext() async throws {
        let store = TabSnapshotStore(directory: Self.directory())
        let first = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        first.put(Self.picture(.systemRed), for: Self.key("a"))
        #expect(first.entry(Self.key("a")).image != nil, "shown at once in this launch")
        try await Self.wait("the picture is written") { first.saves == 1 }

        let next = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        #expect(next.entry(Self.key("a")).image == nil)
        next.warm([Self.key("a"), Self.key("never-seen")])
        try await Self.wait("both reads finish") { next.loads == 2 }
        let image = try #require(next.entry(Self.key("a")).image)
        #expect(image.size.width * image.scale == 40 && image.size.height * image.scale == 56)
        #expect(next.entry(Self.key("never-seen")).image == nil)
    }

    @Test func aPagesSnapshotIsKeptAtTheCardsResolution() async throws {
        let snapshots = TabCardSnapshots(store: TabSnapshotStore(directory: Self.directory()),
                                         memoryPressure: MemoryPressure(observesSystem: false))
        snapshots.put(Self.picture(.systemBlue, width: 1200, height: 2600), for: Self.key("page"), pixelWidth: 520)
        try await Self.wait("the picture is written") { snapshots.saves == 1 }
        let image = try #require(snapshots.entry(Self.key("page")).image)
        #expect(image.size.width * image.scale == 520)
        #expect(snapshots.store.record(Self.key("page"))?.pixelWidth == 520)
    }

    @Test func aMemoryWarningDropsDecodedPicturesAndTheFilesStay() async throws {
        let snapshots = TabCardSnapshots(store: TabSnapshotStore(directory: Self.directory()), limit: 2,
                                         memoryPressure: MemoryPressure(observesSystem: false))
        for tab in ["a", "b", "c"] { snapshots.put(Self.picture(.systemGreen), for: Self.key(tab)) }
        try await Self.wait("the pictures are written") { snapshots.saves == 3 }
        #expect(snapshots.entry(Self.key("a")).image == nil, "past the limit the least recently shown goes")
        #expect(snapshots.entry(Self.key("c")).image != nil)
        snapshots.relieveMemoryPressure()
        #expect(snapshots.entry(Self.key("c")).image == nil)
        snapshots.warm([Self.key("a"), Self.key("c")])
        try await Self.wait("both reads finish") { snapshots.loads == 2 }
        #expect(snapshots.entry(Self.key("a")).image != nil && snapshots.entry(Self.key("c")).image != nil)
    }

    /// The rasterizer's picture is the tab's last-known picture from then on.
    @Test func anAgentCardsPictureIsKeptAsItsLastKnownPicture() async throws {
        let snapshots = TabCardSnapshots(store: TabSnapshotStore(directory: Self.directory()),
                                         memoryPressure: MemoryPressure(observesSystem: false))
        var turn = AgentTurn(id: "t", prompt: "Card", promptAt: Date(timeIntervalSince1970: 0))
        turn.items = [.message(id: "m", markdown: "Reply")]
        turn.status = .completed
        let feed = AgentCardFeed(store: AgentChatStore(source: Silent()))
        feed.snapshotKey = Self.key("agent")
        let page = CGSize(width: 402, height: 874)
        let key = AgentCardRasterKey.current(feed, turns: [turn], colorScheme: .dark, page: page, visibleHeight: 566,
                                             topInset: 70, bottomInset: 110, scale: 1)
        let rasterizer = AgentCardRasterizer(memoryPressure: MemoryPressure(observesSystem: false))
        rasterizer.snapshots = snapshots
        rasterizer.want(feed, key)
        rasterizer.setIdle(true)
        rasterizer.frame()
        rasterizer.setIdle(false)
        try #require(feed.raster != nil)
        #expect(snapshots.entry(Self.key("agent")).image != nil)
        try await Self.wait("the picture is written") { snapshots.saves == 1 }
        #expect(snapshots.store.record(Self.key("agent"))?.pixelWidth == 402)
    }

    /// What a card draws: a still whenever one exists, the live page of transcript only when none does.
    @Test func aCardShowsAStillWheneverOneExists() {
        typealias Card = AgentTabCard
        // A chat whose history is still loading has no turns: its last-known picture, not an empty page.
        #expect(Card.face(awaitingHistory: true, mayShowPicture: true, drawable: true, hasLastKnown: true) == .lastKnown)
        #expect(Card.face(awaitingHistory: true, mayShowPicture: false, drawable: true, hasLastKnown: true) == .lastKnown)
        // Its own picture when it has one.
        #expect(Card.face(awaitingHistory: false, mayShowPicture: true, drawable: true, hasLastKnown: true) == .picture)
        // No picture drawn yet in this launch (the grid is moving): the last-known one, never a live layout.
        #expect(Card.face(awaitingHistory: false, mayShowPicture: false, drawable: true, hasLastKnown: true) == .lastKnown)
        // An image still loading is loaded by a live row only.
        #expect(Card.face(awaitingHistory: false, mayShowPicture: false, drawable: false, hasLastKnown: true) == .live)
        // A tab never seen: live, as before.
        #expect(Card.face(awaitingHistory: false, mayShowPicture: false, drawable: true, hasLastKnown: false) == .live)
        #expect(Card.face(awaitingHistory: true, mayShowPicture: false, drawable: true, hasLastKnown: false) == .live)
    }
    // MARK: What the Mac pushes (`MacTabCards`)

    static func hash(_ data: Data) -> String { TabSnapshotStore.hash(data) }

    static func cards(_ directory: URL, account: String? = "user-1") -> (MacTabCards, TabCardSnapshots) {
        let store = TabSnapshotStore(directory: directory)
        let snapshots = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        snapshots.accountID = { account }
        return (MacTabCards(store: store, snapshots: snapshots), snapshots)
    }

    static func png(_ color: UIColor) throws -> Data { try #require(picture(color, width: 8, height: 8).pngData()) }

    @Test func aMacsBlobsAreKeptPerAccountAndMacApartFromThePhonesPictures() throws {
        let store = TabSnapshotStore(directory: Self.directory())
        let bytes = Data("favicon".utf8), hash = Self.hash(bytes)
        store.save(bytes, pixelWidth: 4, pixelHeight: 6, capturedAtMs: 10, source: .phone, for: Self.key("a"))
        store.putMacBlob(bytes, hash: hash, accountID: "user-1", macID: "mac-1")
        #expect(store.macBlob(hash, accountID: "user-1", macID: "mac-1") == bytes)
        #expect(store.macBlob(hash, accountID: "user-2", macID: "mac-1") == nil, "another account reads nothing")
        #expect(store.macBlob(hash, accountID: "user-1", macID: "mac-2") == nil, "another Mac reads nothing")
        store.removeMacBlobs([hash], accountID: "user-1", macID: "mac-1")
        #expect(store.macBlob(hash, accountID: "user-1", macID: "mac-1") == nil)
        #expect(store.picture(Self.key("a")) == bytes, "the phone's own picture of the same bytes stays")
        // A name that is not a hash never becomes a path.
        store.putMacBlob(bytes, hash: "../../escape", accountID: "user-1", macID: "mac-1")
        #expect(store.macDisk(accountID: "user-1", macID: "mac-1").names.isEmpty)
    }

    @Test func aCardFillsFromWhatTheMacSendsAndAgainOnTheNextLaunch() async throws {
        let directory = Self.directory()
        let favicon = try Self.png(.systemBlue), thumb = try Self.png(.systemGreen), screen = Data("$ ls\nREADME.md".utf8)
        let web = MacCardInfo(title: "Docs", kind: "browser", faviconHash: Self.hash(favicon), thumbHash: Self.hash(thumb), capturedAtMs: 50)
        let shell = MacCardInfo(title: "zsh", kind: "terminal", screenHash: Self.hash(screen), screenColumns: 80, screenRows: 24, capturedAtMs: 50)

        let (first, pictures) = Self.cards(directory)
        #expect(first.heldBlobs(macID: "mac-1").isEmpty)
        first.cards([(tabID: "web", info: web), (tabID: "shell", info: shell)], macID: "mac-1")
        #expect(first.entry(Self.key("web")).info?.title == "Docs", "the title is there with the row")
        #expect(first.entry(Self.key("web")).favicon == nil)
        for (bytes, tab) in [(favicon, "web"), (thumb, "web"), (screen, "shell")] {
            first.save(bytes, hash: Self.hash(bytes), macID: "mac-1")
            await first.blobArrived(hash: Self.hash(bytes), tabIDs: [tab], macID: "mac-1")?.value
        }
        #expect(first.entry(Self.key("web")).favicon != nil)
        #expect(first.entry(Self.key("shell")).screen == "$ ls\nREADME.md")
        #expect(pictures.entry(Self.key("web")).image != nil, "the Mac's thumbnail is the card's picture")
        #expect(Set(first.heldBlobs(macID: "mac-1")) == [Self.hash(favicon), Self.hash(thumb), Self.hash(screen)])
        let store = first.store
        try await Self.wait("rows and blobs are written") {
            let disk = store.macDisk(accountID: "user-1", macID: "mac-1")
            return disk.names.count == 3 && disk.cards.count == 2
        }

        // The next launch, before any link: everything from disk.
        let (next, nextPictures) = Self.cards(directory)
        await next.warm(macID: "mac-1")?.value
        #expect(next.warm(macID: "mac-1") == nil, "one read per Mac and launch")
        #expect(next.entry(Self.key("web")).info == web)
        #expect(next.entry(Self.key("web")).favicon != nil)
        #expect(next.entry(Self.key("shell")).screen == "$ ls\nREADME.md")
        #expect(Set(next.heldBlobs(macID: "mac-1")).count == 3, "the Mac is told what the phone holds")
        try await Self.wait("the thumbnail is read") { nextPictures.entry(Self.key("web")).image != nil }

        // Another account on the same phone sees none of it.
        let (other, _) = Self.cards(directory, account: "user-2")
        await other.warm(macID: "mac-1")?.value
        #expect(other.entry(Self.key("web", account: "user-2")).info == nil)
        #expect(other.heldBlobs(macID: "mac-1").isEmpty)
    }

    /// What a card was handed (`whenScreen`).
    @MainActor final class Shown { var values: [String] = [] }

    /// A cold launch builds a terminal's card (which copies the screen into its model) before
    /// the disk read is done: the card is still handed the screen when the read brings it. Before,
    /// it read an empty entry once and stayed the labeled placeholder (fleet run 397091ff:
    /// every terminal card `placeholder` on the cold launch, browsers and agents filled).
    @Test func aTerminalCardBuiltBeforeTheDiskReadGetsItsScreen() async throws {
        let directory = Self.directory()
        let store = TabSnapshotStore(directory: directory)
        let screen = Data("$ git status\nnothing to commit".utf8)
        store.putMacBlob(screen, hash: Self.hash(screen), accountID: "user-1", macID: "mac-1")
        store.putMacCards(["shell": MacCardInfo(title: "zsh", kind: "terminal", screenHash: Self.hash(screen),
                                                screenColumns: 60, screenRows: 2, capturedAtMs: 50)],
                          accountID: "user-1", macID: "mac-1")

        let (cards, _) = Self.cards(directory)
        let shown = Shown()
        // The card is built first: nothing read yet.
        cards.whenScreen(Self.key("shell")) { shown.values.append($0) }
        #expect(shown.values.isEmpty)
        await cards.warm(macID: "mac-1")?.value
        #expect(shown.values == ["$ git status\nnothing to commit"], "the card gets the screen the disk held")
        // Once read, a card built later gets it at once.
        cards.whenScreen(Self.key("shell")) { shown.values.append($0) }
        #expect(shown.values.count == 2)
    }

    @Test func aFaviconStaysUntilItsReplacementIsHere() async throws {
        let (cards, _) = Self.cards(Self.directory())
        let old = try Self.png(.systemRed), new = try Self.png(.systemTeal)
        cards.cards([(tabID: "web", info: MacCardInfo(title: "A", kind: "browser", faviconHash: Self.hash(old)))], macID: "mac-1")
        cards.save(old, hash: Self.hash(old), macID: "mac-1")
        await cards.blobArrived(hash: Self.hash(old), tabIDs: ["web"], macID: "mac-1")?.value
        let shown = try #require(cards.entry(Self.key("web")).favicon)

        cards.cards([(tabID: "web", info: MacCardInfo(title: "B", kind: "browser", faviconHash: Self.hash(new)))], macID: "mac-1")
        #expect(cards.entry(Self.key("web")).info?.title == "B")
        #expect(cards.entry(Self.key("web")).favicon === shown, "the old favicon, not a blank, until the new one arrives")
        cards.save(new, hash: Self.hash(new), macID: "mac-1")
        await cards.blobArrived(hash: Self.hash(new), tabIDs: ["web"], macID: "mac-1")?.value
        #expect(cards.entry(Self.key("web")).favicon !== shown)

        // A tab the Mac no longer lists loses its row.
        cards.cards([], macID: "mac-1")
        #expect(cards.entry(Self.key("web")).info == nil)
    }

    @Test func anOlderMacPictureNeverReplacesANewerOneOfThePhones() async throws {
        let (cards, pictures) = Self.cards(Self.directory())
        pictures.put(Self.picture(.systemRed), for: Self.key("web"), now: Date(timeIntervalSince1970: 100))
        let own = try #require(pictures.entry(Self.key("web")).image)
        let stale = try Self.png(.systemGreen), fresh = try Self.png(.systemBlue)
        for (bytes, ms) in [(stale, Int64(50_000)), (fresh, Int64(200_000))] {
            cards.cards([(tabID: "web", info: MacCardInfo(title: "A", kind: "browser", thumbHash: Self.hash(bytes), capturedAtMs: ms))], macID: "mac-1")
            cards.save(bytes, hash: Self.hash(bytes), macID: "mac-1")
            await cards.blobArrived(hash: Self.hash(bytes), tabIDs: ["web"], macID: "mac-1")?.value
            if ms < 100_000 {
                #expect(pictures.entry(Self.key("web")).image === own, "captured before the phone's: not shown")
            } else {
                #expect(pictures.entry(Self.key("web")).image !== own, "captured after: shown")
            }
        }
    }

    @Test func removingTheMacsBlobsLeavesThePhonesPictures() async throws {
        let (cards, pictures) = Self.cards(Self.directory())
        pictures.put(Self.picture(.systemRed), for: Self.key("web"))
        try await Self.wait("the phone's picture is written") { pictures.saves == 1 }
        let favicon = try Self.png(.systemBlue), hash = Self.hash(favicon)
        cards.save(favicon, hash: hash, macID: "mac-1")
        let store = cards.store
        try await Self.wait("the blob is written") { store.macBlob(hash, accountID: "user-1", macID: "mac-1") != nil }
        cards.remove(blobs: [hash], macID: "mac-1")
        #expect(cards.heldBlobs(macID: "mac-1").isEmpty)
        try await Self.wait("the blob is deleted") { store.macBlob(hash, accountID: "user-1", macID: "mac-1") == nil }
        #expect(store.picture(Self.key("web")) != nil)
    }

    @Test func aNewEpochVoidsWhatWasKeptByTabID() async throws {
        let directory = Self.directory()
        let favicon = try Self.png(.systemBlue), thumb = try Self.png(.systemGreen)
        let web = MacCardInfo(title: "Docs", kind: "browser", faviconHash: Self.hash(favicon), thumbHash: Self.hash(thumb), capturedAtMs: 50)
        let (first, _) = Self.cards(directory)
        first.cards([(tabID: "s1", info: web)], epoch: "run-1", macID: "mac-1")
        for bytes in [favicon, thumb] {
            first.save(bytes, hash: Self.hash(bytes), macID: "mac-1")
            await first.blobArrived(hash: Self.hash(bytes), tabIDs: ["s1"], macID: "mac-1")?.value
        }
        let store = first.store
        try await Self.wait("rows, epoch and blobs are written") {
            let disk = store.macDisk(accountID: "user-1", macID: "mac-1")
            return disk.names.count == 2 && disk.cards.count == 1 && disk.epoch == "run-1"
        }

        // The next launch shows what was kept; the same epoch keeps it.
        let (same, samePictures) = Self.cards(directory)
        await same.warm(macID: "mac-1")?.value
        try await Self.wait("the thumbnail is read") { samePictures.entry(Self.key("s1")).image != nil }
        same.cards([(tabID: "s1", info: web)], epoch: "run-1", macID: "mac-1")
        #expect(same.entry(Self.key("s1")).favicon != nil, "the same run's tab keeps its favicon")
        #expect(samePictures.entry(Self.key("s1")).image != nil)

        // A reconnect to the same daemon starts a new epoch with the same tabs: nothing blanks.
        let moved = MacCardInfo(title: "Docs: install", kind: "browser", faviconHash: Self.hash(favicon), capturedAtMs: 60)
        same.cards([(tabID: "s1", info: moved)], epoch: "run-1b", macID: "mac-1")
        #expect(same.entry(Self.key("s1")).favicon != nil, "the same page under a new epoch keeps its favicon")
        #expect(samePictures.entry(Self.key("s1")).image != nil, "and its picture")
        #expect(MacTabCards.sameTab(web, MacCardInfo(title: "Docs", kind: "browser")))
        #expect(!MacTabCards.sameTab(web, MacCardInfo(title: "Docs", kind: "terminal")))
        #expect(!MacTabCards.sameTab(web, MacCardInfo(title: "News", kind: "browser")))

        // Another epoch where `s1` is another tab. A terminal must not show the page's favicon or picture.
        let (next, nextPictures) = Self.cards(directory)
        await next.warm(macID: "mac-1")?.value
        try await Self.wait("the thumbnail is read") { nextPictures.entry(Self.key("s1")).image != nil }
        let entry = next.entry(Self.key("s1"))
        next.cards([(tabID: "s1", info: MacCardInfo(title: "zsh", kind: "terminal"))], epoch: "run-2", macID: "mac-1")
        #expect(next.entry(Self.key("s1")) === entry, "the card's views keep observing the same entry")
        #expect(entry.info?.title == "zsh")
        #expect(entry.favicon == nil, "the other tab's favicon is gone")
        #expect(nextPictures.entry(Self.key("s1")).image == nil, "the other tab's picture is gone")
        // Blobs are named by content: a row of the new epoch that names one shows it from disk.
        next.cards([(tabID: "s1", info: MacCardInfo(title: "zsh", kind: "terminal")), (tabID: "s9", info: web)], epoch: "run-2", macID: "mac-1")
        try await Self.wait("the kept favicon fills the tab that names it") { next.entry(Self.key("s9")).favicon != nil }
    }
}
#endif
