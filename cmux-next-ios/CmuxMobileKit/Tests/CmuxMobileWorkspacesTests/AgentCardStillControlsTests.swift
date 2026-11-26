// AgentCardRasterizer is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

/// Leo, 2026-11-17: "Weird placeholder for retries esp in preview". A tab card's picture is an
/// `ImageRenderer` still of the chat (`AgentCardRasterizer.render`), and `ImageRenderer` draws only
/// SwiftUI's own views: a control UIKit draws (the error card's Retry with another model `Menu`,
/// an answer's Share and More) came out as the yellow "can't render" placeholder with a red
/// prohibited sign. These fail on any placeholder in a card's picture.
@MainActor @Suite(.serialized) struct AgentCardStillControlsTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "Reviving claude-sr2-coord after rate-limit loop", harness: "claude-sr",
                                          agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let page = CGSize(width: 402, height: 874)
    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// A chat with every row that holds a UIKit control: an answered turn (its action row: Share,
    /// More) and a failed last turn whose error card offers Retry with another model (two models).
    static func chat() -> AgentChatStore {
        let store = AgentChatStore(source: Silent())
        store.apply(.modelsAvailable([ACPModelInfo(id: "opus", name: "Opus"), ACPModelInfo(id: "sonnet", name: "Sonnet")], current: "opus"))
        store.apply(.batch([
            .userMessage(text: "Summarize the queue", promptId: "p1", turnId: "t1", attachments: [], at: at),
            .turnStarted(turnId: "t1", at: at),
            .update(.agentMessageChunk(text: "Three checks are queued; the iOS build is running.", messageId: "m1")),
            .turnResult(turnId: "t1", status: .completed, errorText: nil, at: at.addingTimeInterval(10)),
            .userMessage(text: "Merge it when green", promptId: "p2", turnId: "t2", attachments: [], at: at.addingTimeInterval(20)),
            .turnStarted(turnId: "t2", at: at.addingTimeInterval(20)),
            .turnResult(turnId: "t2", status: .failed, errorText: "API Error: 429 rate_limit_error", at: at.addingTimeInterval(21)),
        ]))
        return store
    }

    /// Pixels of `image` in the placeholder's yellow (about 247, 206, 70). Nothing in the chat's
    /// dark palette is that saturated a yellow.
    static func placeholderPixels(_ image: UIImage) throws -> Int {
        let cg = try #require(image.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        var count = 0
        for pixel in 0 ..< width * height {
            let r = Int(bytes[pixel * 4]), g = Int(bytes[pixel * 4 + 1]), b = Int(bytes[pixel * 4 + 2])
            if r > 200, g > 160, b < 130, r - b > 110 { count += 1 }
        }
        return count
    }

    static func still<V: View>(_ view: V, size: CGSize) -> UIImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// The detector sees the placeholder: the error card's live `Menu`, drawn as a still, is one
    /// (this is what the card showed before). The same card in a still (`chatStill`) is not.
    @Test func theRetryWithMenuIsAPlaceholderInAStillAndItsStandInIsNot() throws {
        let store = Self.chat()
        let turn = try #require(store.turns.last)
        let choice = try #require(RetryModelChoice(store: store, turn: turn), "two models offer Retry with another model")
        func card(still: Bool) -> some View {
            FailureCard(title: "Agent stopped", message: "Claude is rate limited or out of capacity.", retryWith: choice) {}
                .padding(20)
                .background(Color.black)
                .environment(\.chatStill, still)
        }
        let live = try #require(Self.still(card(still: false), size: CGSize(width: 402, height: 260)))
        let standIn = try #require(Self.still(card(still: true), size: CGSize(width: 402, height: 260)))
        // The before and after pictures, for the PR (the run's attachments).
        if let png = live.pngData() { Attachment.record(png, named: "error-card-still-before.png") }
        if let png = standIn.pngData() { Attachment.record(png, named: "error-card-still-after.png") }
        let before = try Self.placeholderPixels(live)
        let after = try Self.placeholderPixels(standIn)
        #expect(before > 300, "a Menu in a still is ImageRenderer's placeholder: \(before) yellow pixels")
        #expect(after == 0, "the stand-in draws the button: \(after) yellow pixels")
    }

    /// The card's picture as the grid draws it: no placeholder anywhere on it.
    @Test func aCardPictureOfAFailedChatHasNoPlaceholder() throws {
        let feed = AgentCardFeed(store: Self.chat())
        let key = AgentCardRasterKey.current(feed, turns: feed.store.turns, colorScheme: .dark, page: Self.page,
                                             visibleHeight: Self.page.height, topInset: 70, bottomInset: 110, scale: 1)
        try #require(key.isDrawable)
        let image = try #require(AgentCardRasterizer.render(feed, key))
        if let png = image.pngData() { Attachment.record(png, named: "card-picture-after.png") }
        let yellow = try Self.placeholderPixels(image)
        #expect(yellow == 0, "the card's picture draws every control: \(yellow) placeholder pixels")
    }

    /// Leo's picture (2026-11-23): a tab card whose "Agent stopped" card leads with Continue (the
    /// turn had done work) and has Details, the placeholder in the second button's place. Both
    /// lead words take the same stand-in; this is the Continue one, in the card and in its picture.
    @Test func aContinueLedStoppedCardHasNoPlaceholderInItsPicture() throws {
        let store = Self.chat()
        store.apply(.batch([
            .userMessage(text: "Run the background suite", promptId: "p3", turnId: "t3", attachments: [], at: Self.at.addingTimeInterval(30)),
            .turnStarted(turnId: "t3", at: Self.at.addingTimeInterval(30)),
            .update(.agentMessageChunk(text: "Starting the background suite.", messageId: "m3")),
            .turnResult(turnId: "t3", status: .failed, errorText: "API Error: 529 overloaded_error", at: Self.at.addingTimeInterval(40)),
        ]))
        let turn = try #require(store.turns.last)
        #expect(turn.continuesAfterFailure, "a turn that did work leads with Continue")
        let choice = try #require(RetryModelChoice(store: store, turn: turn))
        func card(still: Bool) -> some View {
            FailureCard(title: "Agent stopped", message: "Background suite stop is rate limited or out of capacity.",
                        detail: "API Error: 529 overloaded_error", retryWith: choice, leadsWithContinue: true) {}
                .padding(20)
                .background(Color.black)
                .environment(\.chatStill, still)
        }
        let live = try #require(Self.still(card(still: false), size: CGSize(width: 402, height: 300)))
        let standIn = try #require(Self.still(card(still: true), size: CGSize(width: 402, height: 300)))
        if let png = live.pngData() { Attachment.record(png, named: "continue-card-still-before.png") }
        if let png = standIn.pngData() { Attachment.record(png, named: "continue-card-still-after.png") }
        #expect(try Self.placeholderPixels(live) > 300, "the live Menu beside Continue is the placeholder in a still")
        #expect(try Self.placeholderPixels(standIn) == 0, "beside Continue the stand-in draws the button")

        let feed = AgentCardFeed(store: store)
        let key = AgentCardRasterKey.current(feed, turns: store.turns, colorScheme: .dark, page: Self.page,
                                             visibleHeight: Self.page.height, topInset: 70, bottomInset: 110, scale: 1)
        try #require(key.isDrawable)
        let picture = try #require(AgentCardRasterizer.render(feed, key))
        if let png = picture.pngData() { Attachment.record(png, named: "continue-card-picture-after.png") }
        #expect(try Self.placeholderPixels(picture) == 0, "the tab card's picture draws Continue's neighbor")
    }

    /// The live preview (shown until the picture is drawn, and as a swipe neighbor) draws the same
    /// stand-ins, so the card does not change when its picture replaces it.
    @Test func theLivePreviewDrawsTheStandInsToo() throws {
        let store = Self.chat()
        let preview = AgentChatPreview(store: store, topInset: 70, bottomInset: 110)
        let image = try #require(Self.still(preview, size: Self.page))
        #expect(try Self.placeholderPixels(image) == 0)
    }
}
#endif
