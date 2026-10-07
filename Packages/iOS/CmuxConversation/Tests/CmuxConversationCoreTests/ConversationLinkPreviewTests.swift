import CoreGraphics
import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationLinkPreviewTests {
    private let apple = URL(string: "https://www.apple.com/iphone/")!

    @Test func aMessageThatIsOnlyTheURLBecomesJustTheCard() throws {
        let split = try #require(ConversationLinkSplit.split(text: " https://www.apple.com/iphone/ ", preview: ConversationLinkPreview(url: apple)))
        #expect(split.bodyText.isEmpty)
    }

    @Test func aTrailingURLSplitsIntoTextThenCard() throws {
        let split = try #require(ConversationLinkSplit.split(text: "look at this apple.com/iphone", preview: ConversationLinkPreview(url: apple)))
        #expect(split.bodyText == "look at this")
        #expect(!split.cardFirst)
    }

    @Test func aLeadingURLPutsTheCardFirst() throws {
        let split = try #require(ConversationLinkSplit.split(text: "https://www.apple.com/iphone/ new phones", preview: ConversationLinkPreview(url: apple)))
        #expect(split.bodyText == "new phones")
        #expect(split.cardFirst)
    }

    @Test func aURLInTheMiddleStaysInlineText() {
        #expect(ConversationLinkSplit.split(text: "see https://www.apple.com/iphone/ for details", preview: ConversationLinkPreview(url: apple)) == nil)
        #expect(ConversationLinkSplit.split(text: "https://www.apple.com/iphone/", preview: nil) == nil)
    }

    // Reference values: Apple's RichLinkView in the Messages configuration,
    // iOS 26.3, 402 pt screen (max card width 286.67).
    private func layout(_ preview: ConversationLinkPreview, maxWidth: CGFloat = 286.67, titleWidth: CGFloat = 254, titleLines: Int = 1, domainWidth: CGFloat = 64) -> ConversationLinkCardLayout {
        ConversationLinkCardLayout.compute(
            preview: preview, maxWidth: maxWidth,
            measureTitle: { _, maxW in CGSize(width: min(titleWidth, maxW), height: CGFloat(titleLines) * 18) },
            measureDomain: { _ in domainWidth },
            measurePrompt: { 122 }
        )
    }

    @Test func landscapeImageFillsTheWidthWithACaptionBelow() throws {
        let preview = ConversationLinkPreview(url: apple, title: "iPhone", image: .init(url: apple, width: 1200, height: 630))
        let l = layout(preview, titleLines: 2)
        #expect(l.kind == .media)
        #expect(l.size.width == 286)
        #expect(l.mediaFrame == CGRect(x: 0, y: 0, width: 286, height: 150))
        #expect(l.titleFrame == CGRect(x: 16, y: 158, width: 254, height: 36))
        #expect(l.domainFrame?.minY == 196)
        #expect(l.size.height == 221, "\(l.size.height)")
    }

    @Test func squareAndTallImagesUseANarrowerCard() {
        let square = layout(ConversationLinkPreview(url: apple, title: "t", image: .init(url: apple, width: 1000, height: 1000)), titleLines: 2)
        #expect(square.size.width == 218)
        #expect(square.mediaFrame?.height == 218)
        #expect(square.size.height == 289)
        let tall = layout(ConversationLinkPreview(url: apple, title: "t", image: .init(url: apple, width: 400, height: 1200)), titleLines: 2)
        #expect(tall.mediaFrame?.height == 654)
    }

    @Test func aSmallImageBecomesATrailingThumbnail() {
        let preview = ConversationLinkPreview(url: apple, title: "t", image: .init(url: apple, width: 120, height: 90))
        let l = layout(preview, maxWidth: 300, titleWidth: 219, titleLines: 2)
        #expect(l.kind == .compact)
        #expect(l.size == CGSize(width: 293, height: 71))
        #expect(l.thumbnailFrame == CGRect(x: 251, y: 20.5, width: 30, height: 30))
        #expect(l.titleFrame?.minY == 8)
    }

    @Test func aBareLinkShowsTheDomainAndFallbackGlyph() {
        let l = layout(ConversationLinkPreview(url: apple), maxWidth: 300)
        #expect(l.kind == .compact)
        #expect(l.size == CGSize(width: 140, height: 59))
        #expect(l.glyphFrame == CGRect(x: 96, y: 13.5, width: 32, height: 32))
        #expect(l.domainFrame?.minY == 22)
    }

    @Test func loadingAndTapToLoadCardsHaveFixedShapes() {
        let loading = layout(ConversationLinkPreview(url: apple, state: .loading))
        #expect(loading.size == CGSize(width: 150, height: 111))
        #expect(loading.spinnerFrame == CGRect(x: 56.5, y: 35, width: 37, height: 37))
        let tap = layout(ConversationLinkPreview(url: apple, state: .tapToLoad))
        #expect(tap.size == CGSize(width: 160, height: 115))
        #expect(tap.promptAreaFrame?.height == 80)
    }

    // macOS 26 LinkPresentation (AppKit LPLinkView, same Messages settings).
    private func macLayout(_ preview: ConversationLinkPreview, titleWidth: CGFloat, domainWidth: CGFloat) -> ConversationLinkCardLayout {
        ConversationLinkCardLayout.compute(
            preview: preview, maxWidth: 300, metrics: .mac,
            measureTitle: { _, maxW in CGSize(width: min(titleWidth, maxW), height: 14) },
            measureDomain: { _ in domainWidth },
            measurePrompt: { 112 }
        )
    }

    @Test func macCardsUseTheMacCaptionAndKeepSmallImagesOnTop() {
        let large = macLayout(ConversationLinkPreview(url: apple, title: "t", image: .init(url: apple, width: 1200, height: 630)), titleWidth: 280, domainWidth: 54)
        #expect(large.size == CGSize(width: 300, height: 201))
        #expect(large.titleFrame == CGRect(x: 10, y: 164, width: 280, height: 14))
        #expect(large.domainFrame?.minY == 180)
        let small = macLayout(ConversationLinkPreview(url: apple, title: "t", image: .init(url: apple, width: 120, height: 90)), titleWidth: 280, domainWidth: 54)
        #expect(small.kind == .media && small.size.height == 225 + 44)
        let icon = macLayout(ConversationLinkPreview(url: apple, title: "t", icon: .init(url: apple, width: 180, height: 180)), titleWidth: 204, domainWidth: 54)
        #expect(icon.size == CGSize(width: 266, height: 44))
        #expect(icon.thumbnailFrame == CGRect(x: 224, y: 7, width: 30, height: 30))
        let bare = macLayout(ConversationLinkPreview(url: apple), titleWidth: 0, domainWidth: 54)
        #expect(bare.size == CGSize(width: 118, height: 60))
        #expect(bare.glyphFrame == CGRect(x: 74, y: 14, width: 32, height: 32))
        let tap = macLayout(ConversationLinkPreview(url: apple, state: .tapToLoad), titleWidth: 0, domainWidth: 54)
        #expect(tap.size == CGSize(width: 160, height: 109))
        #expect(tap.domainFrame?.minY == 88)
        let loading = macLayout(ConversationLinkPreview(url: apple, state: .loading), titleWidth: 0, domainWidth: 58)
        #expect(loading.size == CGSize(width: 140, height: 103))
        #expect(loading.spinnerFrame == CGRect(x: 54, y: 35, width: 32, height: 32))
    }

    @Test func domainDropsWWW() {
        #expect(ConversationLinkPreview(url: apple).domain == "apple.com")
        #expect(ConversationLinkPreview(url: apple, siteName: "Apple").domain == "Apple")
    }
}

@MainActor
@Suite struct ConversationLinkPreviewStoreTests {
    @Test func tapToLoadFetchesTheCardAndKeepsItThroughServerUpdates() async throws {
        let backend = ScriptedBackend(total: 3)
        let url = URL(string: "https://example.com/a")!
        backend.linkPreviews[url] = ConversationLinkPreview(url: url, title: "Example")
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        var live = backend.makeMessage(seq: 4, sender: "lc")
        live.text = url.absoluteString
        live.linkPreview = ConversationLinkPreview(url: url, state: .tapToLoad)
        store.apply(.message(live, eventSeq: 100))

        store.loadLinkPreview(messageID: live.id)
        #expect(store.message(id: live.id)?.linkPreview?.state == .loading)
        try await waitUntil { store.message(id: live.id)?.linkPreview?.state == .loaded }
        #expect(store.message(id: live.id)?.linkPreview?.title == "Example")

        // A tapback arrives with the server's tap-to-load stub; the loaded card stays.
        live.reactions = [ConversationReactionMark(participantID: "me", reaction: .heart)]
        store.apply(.message(live, eventSeq: 101))
        #expect(store.message(id: live.id)?.linkPreview?.title == "Example")
    }

    @Test func thePendingSendShowsTheComposerPreviewUntilTheAckCarriesOne() async throws {
        let backend = ScriptedBackend(total: 3)
        let url = URL(string: "https://example.com/a")!
        let store = ConversationStore(backend: backend, pageSize: 30)
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        let rowID = try #require(store.send(text: url.absoluteString, linkPreview: ConversationLinkPreview(url: url, title: "Example")))
        #expect(store.message(rowID: rowID)?.linkPreview?.title == "Example")
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(store.message(rowID: rowID)?.linkPreview?.title == "Example")
    }
}
