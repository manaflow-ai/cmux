import Foundation
@testable import CmuxNextUpdater
import Testing

/// The Update Ready popup's pictures (Leo 2026-10-19): a change's screenshot reaches the popup's
/// page only after the host inlined and checked it (`ReleaseMediaStore`), as a `data:` URL; a
/// remote or unchecked file never does.
@Suite struct UpdateHighlightsMediaTests {
    private let png = "data:image/png;base64,iVBORw0KGgo="
    private let pngDark = "data:image/png;base64,AAAA"

    private func notes(entryMedia: WhatsNewDocument.Media?, highlightMedia: [ReleaseNotes.Media] = []) -> ReleaseNotes {
        let document = WhatsNewDocument(
            version: "1.0.0-nightly.3932981759301", channel: .nightly, date: "2026-10-19", headline: "Groups",
            entries: [
                WhatsNewDocument.Entry(id: "groups", category: .new, title: "Workspace groups", summary: "Colored labels", media: entryMedia),
                WhatsNewDocument.Entry(id: "undo", category: .new, title: "Undo a tab close", summary: "From a toast"),
            ])
        return ReleaseNotes(version: 1, build: "3932981759301", shortVersion: "1.0.0-nightly.3932981759301", date: "2026-10-19",
                            highlights: [ReleaseNotes.Highlight(id: "groups", title: "Workspace groups", body: "Colored labels",
                                                                media: highlightMedia, action: nil)],
                            changes: [], whatsNew: document)
    }

    private func highlights(_ notes: ReleaseNotes) -> UpdateHighlights {
        UpdateHighlights(version: notes.shortVersion, build: notes.build, fromVersion: "1.0.0-nightly.1", fromBuild: "1",
                         notes: notes, appcast: nil, languages: ["en"])
    }

    @Test func anInlinedEntryPictureReachesItsItem() {
        let inlined = notes(entryMedia: WhatsNewDocument.Media(kind: "image", light: png, dark: pngDark, alt: "The sidebar"))
        let result = highlights(inlined).withMedia(from: inlined, languages: ["en"])
        #expect(result.items.map(\.id) == ["groups", "undo"])
        #expect(result.items[0].media == UpdateHighlights.Media(light: png, dark: pngDark, alt: "The sidebar"))
        #expect(result.items[1].media == nil)
    }

    @Test func aRemoteOrUncheckedPictureNeverReachesThePage() {
        let remote = notes(entryMedia: WhatsNewDocument.Media(kind: "image", light: "media/1.0/groups.png",
                                                              dark: "https://cmux.com/whats-new/media/1.0/groups.png", alt: "x"),
                           highlightMedia: [ReleaseNotes.Media(url: URL(string: "https://files.cmux.com/a.png")!, sha256: "00", kind: "image", alt: "x")])
        let result = highlights(remote).withMedia(from: remote, languages: ["en"])
        #expect(result.items.allSatisfy { $0.media == nil })
    }

    @Test func plainHighlightsCarryNoPictureAndStillDecodeWithout() throws {
        let inlined = notes(entryMedia: WhatsNewDocument.Media(kind: "image", light: png, dark: png, alt: "x"))
        // Built straight from the notes (what a saved update record keeps): no picture.
        #expect(highlights(inlined).items.allSatisfy { $0.media == nil })
        // A record saved before this field decodes.
        let old = #"{"id":"a","title":"A","summary":null,"category":"new"}"#
        let item = try JSONDecoder().decode(UpdateHighlights.Item.self, from: Data(old.utf8))
        #expect(item.media == nil)
    }
}
