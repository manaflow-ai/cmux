import AppKit
import CmuxNextDesign
@testable import CmuxNextHomeEngine
import Testing

/// Leo's screenshot of the Chief Settings card (2026-10-20): a Chief whose face is an emoji showed
/// it small on a large grey disc, beside the header's full-size face. An emoji fills the card's
/// disc with nothing behind it; letters stay a monogram on the disc.
@MainActor @Suite struct HomeChiefSettingsAvatarFaceTests {
    static func view() -> HomeChiefSettingsView {
        HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: AvatarOfflineChief())
    }

    @Test func anEmojiFaceFillsTheDisc() throws {
        let view = Self.view()
        view.setAvatar(picture: nil, text: "\u{1FAE1}")
        let button = view.avatarButton
        let font = try #require(button.font)
        #expect(button.showsEmoji)
        #expect(font.pointSize >= HomeChiefSettingsView.avatarSize * 0.7, "the emoji is \(font.pointSize) pt on a \(HomeChiefSettingsView.avatarSize) pt disc")
        #expect(button.layer?.backgroundColor == nil, "a grey disc behind the emoji")
    }

    @Test func lettersStayAMonogramOnTheDisc() throws {
        let view = Self.view()
        view.setAvatar(picture: nil, text: "LL")
        let button = view.avatarButton
        #expect(!button.showsEmoji)
        #expect(try #require(button.font).pointSize == TypeScale.heading)
        #expect(button.layer?.backgroundColor != nil)
    }

    @Test func aPictureHasNoDiscAndNoText() {
        let view = Self.view()
        view.setAvatar(picture: NSImage(size: NSSize(width: 8, height: 8)), text: "\u{1FAE1}")
        #expect(!view.avatarButton.showsEmoji)
        #expect(view.avatarButton.title.isEmpty)
        #expect(view.avatarButton.layer?.backgroundColor == nil)
    }
}

private struct AvatarOfflineChief: HomeChiefEngineSource {
    var isLocal: Bool { true }
    var place: String? { nil }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
}
