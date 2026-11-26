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
            // A stripe: a picture of one solid colour is a placeholder (`CardPictureGate`), never kept.
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: max(1, width / 4), height: height))
        }
    }

    static func solid(_ color: UIColor, width: CGFloat = 40, height: CGFloat = 56) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Polls until `done`, up to 30 s. The simulator leg runs the kit's ~2900 tests in parallel
    /// (`cmux-next-ios-sim.sh test`), and this store's encodes, reads and writes run off the main
    /// thread at utility priority: on 2026-11-25 a save and a Mac thumbnail read each missed a
    /// 5 s bound there while passing alone. A path that never finishes still fails.
    static func wait(_ what: String, until done: @MainActor () -> Bool) async throws {
        for _ in 0..<3000 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(done(), "\(what) within 30 s")
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

    /// Holds the store's lock while a save of `shared` for `a` and then a close of `b` queue on
    /// it, the save first, then lets both run. Off the main actor, on one thread: the lock is
    /// taken and released by the same thread, and no closure here is the main actor's.
    nonisolated static func saveRacingClose(_ store: TabSnapshotStore, shared: Data, capturedAtMs: Int64,
                                            save a: TabSnapshotKey, close b: TabSnapshotKey) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                store.lock.lock()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) {
                    store.save(shared, pixelWidth: 1, pixelHeight: 1, capturedAtMs: capturedAtMs, source: .phone, for: a)
                }
                Thread.sleep(forTimeInterval: 0.02)
                DispatchQueue.global().async(group: group) { store.remove(b) }
                Thread.sleep(forTimeInterval: 0.02)
                store.lock.unlock()
                group.wait()
                done.resume()
            }
        }
    }

    /// A save's blob and record are written under one lock: another tab closing in between
    /// found the new blob unnamed and deleted it, leaving a record whose picture was gone.
    @Test func aSaveRacingAnotherTabsCloseKeepsItsPicture() async throws {
        let store = TabSnapshotStore(directory: Self.directory())
        let shared = Data("shared".utf8), a = Self.key("a"), b = Self.key("b")
        for round in 0..<5 {
            let ms = Int64(round * 10)
            // "a" names a picture of its own; "b" alone names the shared one.
            store.save(Data("own-\(round)".utf8), pixelWidth: 1, pixelHeight: 1, capturedAtMs: ms, source: .phone, for: a)
            store.save(shared, pixelWidth: 1, pixelHeight: 1, capturedAtMs: ms, source: .phone, for: b)
            // Both calls queue on the held lock, the save first; on release the close used to
            // run between the save's blob and its record.
            await Self.saveRacingClose(store, shared: shared, capturedAtMs: ms + 1, save: a, close: b)
            #expect(store.picture(a) == shared, "round \(round): the record's blob is on disk")
        }
    }

    /// A tab closed while its picture was still being encoded: the late save never writes it back.
    @Test func aPictureEncodedAfterItsTabClosedIsNotWritten() async throws {
        let store = TabSnapshotStore(directory: Self.directory())
        let snapshots = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        snapshots.put(Self.picture(.systemRed, width: 1200, height: 2600), for: Self.key("a"), pixelWidth: 520)
        snapshots.remove(Self.key("a"))
        try await Self.wait("the save finishes or is dropped") { snapshots.saves + snapshots.dropped == 1 }
        await snapshots.diskSettled()
        #expect(snapshots.dropped == 1)
        #expect(store.record(Self.key("a")) == nil, "the closed tab's picture is not on disk")
        #expect(snapshots.entry(Self.key("a")).image == nil, "nor on its card")
    }

    /// Sign-out: the account's pictures (its chats' and pages' contents) leave memory and disk;
    /// another account's stay, and so does a blob that account's record names.
    @Test func signingOutRemovesTheAccountsPicturesOnly() async throws {
        let directory = Self.directory()
        let store = TabSnapshotStore(directory: directory)
        let shared = Data("shared".utf8), mine = Data("mine".utf8), favicon = Data("favicon".utf8)
        store.save(mine, pixelWidth: 1, pixelHeight: 1, capturedAtMs: 1, source: .phone, for: Self.key("a"))
        store.save(shared, pixelWidth: 1, pixelHeight: 1, capturedAtMs: 1, source: .phone, for: Self.key("b"))
        store.save(shared, pixelWidth: 1, pixelHeight: 1, capturedAtMs: 1, source: .phone, for: Self.key("b", account: "user-2"))
        store.putMacCards(["web": MacCardInfo(title: "Docs", kind: "browser")], accountID: "user-1", macID: "mac-1")
        store.putMacBlob(favicon, hash: Self.hash(favicon), accountID: "user-2", macID: "mac-1")

        let (cards, snapshots) = Self.cards(directory)
        snapshots.put(Self.picture(.systemRed), for: Self.key("c"))
        try await Self.wait("the picture is written") { snapshots.saves == 1 }
        cards.save(favicon, hash: Self.hash(favicon), macID: "mac-1")
        try await Self.wait("the Mac's blob is written") { store.macBlob(Self.hash(favicon), accountID: "user-1", macID: "mac-1") != nil }
        #expect(!cards.heldBlobs(macID: "mac-1").isEmpty)

        snapshots.signedOut(accountID: "user-1")
        cards.signedOut()
        await snapshots.diskSettled()
        #expect(snapshots.entry(Self.key("c")).image == nil)
        for tab in ["a", "b", "c"] { #expect(store.record(Self.key(tab)) == nil) }
        #expect(!store.hasBlob(TabSnapshotStore.hash(mine)))
        #expect(store.macBlob(Self.hash(favicon), accountID: "user-1", macID: "mac-1") == nil)
        #expect(store.macCards(accountID: "user-1", macID: "mac-1").isEmpty)
        #expect(cards.heldBlobs(macID: "mac-1").isEmpty, "the same account signing in again is not told it holds them")
        #expect(store.picture(Self.key("b", account: "user-2")) == shared, "another account's picture stays")
        #expect(store.macBlob(Self.hash(favicon), accountID: "user-2", macID: "mac-1") == favicon)
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

    /// A picture an earlier build saved with the cannot-draw mark in it (yellow with red) is never shown
    /// on the next launch; a clean one is.
    @Test func aSavedPictureHoldingTheCannotDrawMarkIsNotShown() async throws {
        let store = TabSnapshotStore(directory: Self.directory())
        let first = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let mark = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 56), format: format).image { context in
            UIColor(red: 1, green: 0.85, blue: 0, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 56))
            UIColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
            context.fill(CGRect(x: 10, y: 18, width: 20, height: 20))
        }
        #expect(CannotDrawMark.isIn(mark))
        // Saved as an earlier build did (this one never saves it: `CardPictureGate`).
        store.save(try #require(mark.jpegData(compressionQuality: 0.8)), pixelWidth: 40, pixelHeight: 56,
                   capturedAtMs: 1, source: .phone, for: Self.key("marked"))
        first.put(Self.picture(.systemBlue), for: Self.key("clean"))
        try await Self.wait("the clean picture is written") { first.saves == 1 }

        let next = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        next.warm([Self.key("marked"), Self.key("clean")])
        try await Self.wait("both reads finish") { next.loads == 2 }
        #expect(next.entry(Self.key("marked")).image == nil, "the mark is never on a card")
        #expect(next.entry(Self.key("clean")).image != nil)
    }

    /// Leo, 2026-11-24: "there are too many empty previews in the safari grid thing". A page with
    /// little on it (a short chat) is a picture of its tab, not a placeholder: a few thin strokes
    /// anywhere on a page-sized picture keep it, though a 64-pixel copy of it reads as one colour.
    @Test func aSparsePageIsAPictureNotAPlaceholder() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 1206, height: 2622)
        for mark in [CGRect(x: 611, y: 1307, width: 2, height: 2), CGRect(x: 1203, y: 2619, width: 3, height: 1),
                     CGRect(x: 0, y: 0, width: 1, height: 1)] {
            let page = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.white.setFill()
                context.fill(mark)
            }
            #expect(!CardPictureGate.isPlaceholder(page), "a page with \(mark) drawn is a picture")
        }
        #expect(CardPictureGate.isPlaceholder(Self.solid(.black, width: 1206, height: 2622)))
    }

    /// Leo, 2026-11-24, on a grid of black cards: "wer need to chase all these placeholders doen and
    /// prevent them". A picture of one solid colour (a capture of a page that had drawn nothing) is
    /// neither shown nor saved, from the phone or the Mac; the card keeps its last real picture.
    @Test func aSolidPictureIsNeverShownOrSaved() async throws {
        #expect(CardPictureGate.isPlaceholder(Self.solid(.black)))
        #expect(CardPictureGate.isPlaceholder(Self.solid(.white, width: 1200, height: 2600)))
        #expect(!CardPictureGate.isPlaceholder(Self.picture(.black)))
        let store = TabSnapshotStore(directory: Self.directory())
        let snapshots = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        snapshots.put(Self.picture(.systemRed), for: Self.key("a"))
        try await Self.wait("the real picture is written") { snapshots.saves == 1 }
        let real = store.picture(Self.key("a"))
        snapshots.put(Self.solid(.black), for: Self.key("a"))
        snapshots.put(Self.solid(.black, width: 1200, height: 2600), for: Self.key("page"), pixelWidth: 520)
        try await Self.wait("the black one is dropped and the real one read back") {
            snapshots.entry(Self.key("a")).image.map { !CardPictureGate.isPlaceholder($0) } ?? false
        }
        await snapshots.diskSettled()
        #expect(snapshots.saves == 1, "no black picture is saved")
        #expect(store.picture(Self.key("a")) == real)
        #expect(snapshots.entry(Self.key("page")).image == nil)

        let (cards, pictures) = Self.cards(Self.directory())
        let black = try #require(Self.solid(.black, width: 8, height: 8).pngData())
        cards.cards([(tabID: "web", info: MacCardInfo(title: "A", kind: "browser", thumbHash: Self.hash(black), capturedAtMs: 10))], macID: "mac-1")
        cards.save(black, hash: Self.hash(black), macID: "mac-1")
        await cards.blobArrived(hash: Self.hash(black), tabIDs: ["web"], macID: "mac-1")?.value
        #expect(pictures.entry(Self.key("web")).image == nil, "the Mac's black thumbnail is not a card's picture")
    }

    /// Leo's 51 tabs: a list's warm reads its first `limit`; a card that appears reads its own, so
    /// one past the limit, or one evicted since, shows its picture rather than a stand-in.
    @Test func aCardPastTheWarmLimitOrEvictedIsReadWhenItAppears() async throws {
        let store = TabSnapshotStore(directory: Self.directory())
        let first = TabCardSnapshots(store: store, memoryPressure: MemoryPressure(observesSystem: false))
        for tab in ["a", "b", "c"] { first.put(Self.picture(.systemGreen), for: Self.key(tab)) }
        try await Self.wait("the pictures are written") { first.saves == 3 }

        let next = TabCardSnapshots(store: store, limit: 2, memoryPressure: MemoryPressure(observesSystem: false))
        next.warm([Self.key("a"), Self.key("b"), Self.key("c")])
        try await Self.wait("the list's reads finish") { next.loads == 2 }
        #expect(next.entry(Self.key("c")).image == nil)
        next.warm(Self.key("c"))
        try await Self.wait("the appearing card's read finishes") { next.loads == 3 }
        #expect(next.entry(Self.key("c")).image != nil)
        let evicted = try #require(["a", "b"].first { next.entry(Self.key($0)).image == nil }, "one of a and b was evicted")
        next.warm(Self.key(evicted))
        try await Self.wait("the evicted card's read finishes") { next.loads == 4 }
        #expect(next.entry(Self.key(evicted)).image != nil)
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
        let raster = try #require(feed.raster)
        // A raster the gate calls a placeholder is never saved: say so rather than time out below.
        #expect(!CardPictureGate.isPlaceholder(raster.image), "the agent card's picture reads as a placeholder")
        #expect(snapshots.entry(Self.key("agent")).image != nil)
        try await Self.wait("the picture is written") { snapshots.saves == 1 }
        #expect(snapshots.store.record(Self.key("agent"))?.pixelWidth == 402)
    }

    /// A chat shorter than its page rests on the composer, below the part of the page a card
    /// shows: its card was one flat colour and was never kept (Leo, 2026-11-24: "there are too
    /// many empty previews in the safari grid thing"; measured on the fleet simulator, 402x566,
    /// 0 pixels off the background, while the whole page drew its text). In a card its rows sit
    /// inside the slice.
    @Test func aShortChatsCardShowsItsRows() throws {
        var turn = AgentTurn(id: "t", prompt: "Card", promptAt: Date(timeIntervalSince1970: 0))
        turn.items = [.message(id: "m", markdown: "Reply")]
        turn.status = .completed
        let feed = AgentCardFeed(store: AgentChatStore(source: Silent()))
        let page = CGSize(width: 402, height: 874)
        for scheme in [ColorScheme.dark, .light] {
            let key = AgentCardRasterKey.current(feed, turns: [turn], colorScheme: scheme, page: page, visibleHeight: 566,
                                                 topInset: 70, bottomInset: 110, scale: 1)
            let image = try #require(AgentCardRasterizer.render(feed, key))
            #expect(!CardPictureGate.isPlaceholder(image), "a short chat's card is one flat colour (\(scheme))")
        }
    }

    /// Where a card's rows rest: on the slice's bottom edge when the page would rest them below
    /// it, under the header when they are taller than the slice, and as the page (no move on
    /// open) once they fill the page.
    @Test func aCardsRowsRestInsideItsSlice() {
        func top(_ rows: CGFloat, slice: CGFloat? = 566) -> CGFloat {
            AgentChatPreviewPlacement.rowsTop(pageHeight: 874, rowsHeight: rows, topInset: 70, bottomInset: 110, cardSlice: slice)
        }
        // The page at rest (no slice): on the composer's gap.
        #expect(top(100, slice: nil) == 664)
        // A short chat: wholly inside the slice, on its bottom edge.
        #expect(top(100) + 100 <= 566 && top(100) >= 70)
        let onTheSlicesEdge: CGFloat = 566 - 8 - 100
        #expect(top(100) == onTheSlicesEdge)
        // Taller than the slice: from under the header.
        #expect(top(600) == 70)
        // Filling the page: as the page rests it.
        #expect(top(700) == 64)
        #expect(top(3000) == top(3000, slice: nil))
        // No step between the cases.
        #expect(abs(top(487) - top(489)) <= 2 && abs(top(693) - top(695)) <= 2)
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
