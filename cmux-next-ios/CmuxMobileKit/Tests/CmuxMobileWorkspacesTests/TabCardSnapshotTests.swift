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
}
#endif
