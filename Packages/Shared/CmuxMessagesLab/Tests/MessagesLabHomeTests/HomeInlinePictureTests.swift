import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Lawrence, 2026-11-20: the Chief shows a screenshot as `![alt](/abs/shot.png)` on its own line, and its bubble
/// drew that as "!alt", a link with a stray "!". A picture on a line of its own is the picture, in its place; a
/// picture inside a sentence shows its alt text as a link to it, never the "!".
@MainActor @Suite(.serialized) struct HomeInlinePictureTests {
    init() {
        HomeMarkdownPolicy.install()
    }

    static let shot = "/tmp/a1317/shots/before-light.png"
    static let thumbnail = "/tmp/a1317/thumbs/before-light.png"

    /// The Chief's parts for `text`, with `media` resolving picture sources (as HomeProjection's lookup does).
    static func parts(_ text: String, media: @escaping HomeMapping.Media) -> [Part] {
        HomeMapping.parts(.text(text), media: media, markdown: true)
    }

    static func shown(_ parts: [Part]) -> String {
        parts.compactMap { if case let .text(t, _) = $0 { t } else { nil } }.joined(separator: "\n")
    }

    static func pictures(_ parts: [Part]) -> [MessagesLabHome.Attachment] {
        parts.compactMap { if case let .attachment(a) = $0, a.kind == "image" { a } else { nil } }
    }

    @Test func aPictureOnItsOwnLineIsAPictureInItsPlace() throws {
        let parts = Self.parts("Before the fix:\n![before, light](\(Self.shot))\nAfter it.") { $0 == Self.shot ? Self.thumbnail : nil }
        let picture = try #require(Self.pictures(parts).first, "no picture bubble: \(parts)")
        #expect(picture.asset == URL(fileURLWithPath: Self.thumbnail).absoluteString)
        #expect(picture.fileName == "before, light")
        #expect(parts.count == 3, "the picture sits between the words before and after it: \(parts)")
        #expect(!Self.shown(parts).contains("!"), "the bubble still shows picture syntax: \(Self.shown(parts).debugDescription)")
        #expect(Self.shown(parts) == "Before the fix:\nAfter it.")
    }

    @Test func aPictureStillLoadingHoldsItsPlaceAtItsSize() throws {
        let parts = Self.parts("![before, light](\(Self.shot))") { $0 == Self.shot ? HomeTablePictures.loadingPrefix + "2560x1600" : nil }
        let picture = try #require(Self.pictures(parts).first, "no picture bubble: \(parts)")
        #expect(picture.asset == nil)
        #expect(picture.width == 2560 && picture.height == 1600)
    }

    @Test func aPictureWithNoFileShowsItsAltTextWithoutTheBang() {
        let parts = Self.parts("![before, light](\(Self.shot))") { _ in nil }
        #expect(Self.pictures(parts).isEmpty)
        #expect(Self.shown(parts) == "before, light")
    }

    @Test func aPictureInsideASentenceShowsItsAltTextAsALink() {
        let rendered = HomeMarkdown.render("See ![the shot](\(Self.shot)) for the fix")
        #expect(rendered.text == "See the shot for the fix")
        let run = rendered.runs.first { $0.link != nil }
        #expect(run.map { (rendered.text as NSString).substring(with: NSRange(location: $0.start, length: $0.length)) } == "the shot")
    }

    @Test func aPictureWithNoAltTextShowsItsFileName() {
        #expect(HomeMarkdown.render("Here: ![](\(Self.shot))").text == "Here: before-light.png")
    }

    /// The quote of a text of two pictures with no file still says how many (HomeQuotePreview reads the tags).
    @Test func aQuoteOfTwoPicturesWithNoFileSaysHowMany() {
        let part = HomeMapping.parts(.text("![before](/tmp/none-a.png) ![after](/tmp/none-b.png)"), markdown: true).first
        guard case let .text(quoted, _)? = HomeQuotePreview.part(part, markdown: true) else {
            Issue.record("no text quote: \(String(describing: part))")
            return
        }
        #expect(quoted == "2 images")
    }
}
