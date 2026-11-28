import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextTabs
import CmuxNextWakeups
import Foundation
import Testing

/// The user, 2026-11-25 (https://github.com/manaflow-ai/cmux/issues/56159): "the terminal and chat previews dont seem
/// to show up". In the sidebar workspace card a browser tab showed its picture, a chat only its title in an empty box
/// and a terminal nothing: browser pages kept their pictures on disk (`BrowserPageFrames`), terminals and chats only in
/// memory, so after a relaunch a tab of any other kind not shown since had nothing to draw. Every kind's card now gets
/// a picture from the card's own provider (`TabPreviewSource`, what `SidebarView.tabPictures` asks).
@MainActor @Suite(.serialized) struct TabCardPicturesTests {
    /// Every tab kind, none shown since the relaunch (no page, no surface, no chat view): each card has a picture.
    @Test func everyTabKindNotShownSinceTheRelaunchHasACardPicture() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let (browser, terminal, chat) = ("browser-tab", "terminal-tab", "chat-tab")
        let (pages, pagesFolder) = try await Self.store(keeping: [browser])
        let (cards, cardsFolder) = try await Self.store(keeping: [terminal, chat])
        defer { [pagesFolder, cardsFolder].forEach { try? FileManager.default.removeItem(at: $0) } }
        services.cache.pageFrames = pages
        services.cache.cardPictures = cards
        let previews = TabPreviewSource(cache: services.cache, pages: services.pages, images: services.launchImages) { _ in nil }
        for key in [browser, terminal, chat] {
            #expect(services.cache.terminals[key] == nil && services.cache.existingBrowser(key) == nil, "setup: \(key) has content")
            #expect(await previews.previewImage(for: TabID(key), maxPixelSize: CGSize(width: 320, height: 160)) != nil, "\(key)'s card had no picture")
        }
    }

    /// A terminal's or chat's card picture is written to the store, read back after a relaunch, and goes with its tab.
    @Test func aCardPictureIsKeptAcrossARelaunchAndGoesWithItsTab() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "tab-card-pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = BrowserPageFrames(directory: folder, capacity: 1 << 20)
        await store.prefetch(on: BackgroundWork()).value
        services.cache.cardPictures = store
        services.cache.keepCardPicture(try Self.striped(), for: "t")
        var relaunched: CGImage?
        let deadline = ContinuousClock.now + .seconds(10)
        while relaunched == nil, ContinuousClock.now < deadline {
            let next = BrowserPageFrames(directory: folder, capacity: 1 << 20)
            await next.prefetch(on: BackgroundWork()).value
            relaunched = await next.lastPicture("t")
            if relaunched == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(relaunched != nil, "the picture was not on disk for the next launch")
        services.cache.release("t")
        #expect(await store.lastPicture("t") == nil, "a closed tab's picture stayed")
    }

    /// A store whose last run kept a picture of each of `keys`.
    static func store(keeping keys: [String]) async throws -> (BrowserPageFrames, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tab-card-pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
        let data = try #require(BrowserPageFrames.encoded(try striped()))
        for key in keys { BrowserPageFrames.write(data, key: key, scale: 2, to: folder, capacity: 1 << 20) }
        let store = BrowserPageFrames(directory: folder, capacity: 1 << 20)
        await store.prefetch(on: BackgroundWork()).value
        return (store, folder)
    }

    /// Light lines on a dark ground: a picture with content (`ThumbnailStats`), as a terminal's output or a chat's turn.
    static func striped() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        for row in stride(from: 12, to: 190, by: 20) { context.fill(CGRect(x: 10, y: row, width: 200 + row % 90, height: 6)) }
        return try #require(context.makeImage())
    }
}
