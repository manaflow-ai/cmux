import CmuxHomeCore
import Foundation

/// Markdown to one plain line, as a list preview: the rows, Chief's pin
/// bubble and its VoiceOver label (F4). Its words, never its syntax
/// (``MessagePreview``, shared with the Mac's Home): links by their labels, a
/// table by its column titles ("Table: Before / After"), pictures left out or
/// counted ("2 images").
///
/// Runs once per row of every Home read, so a text with nothing to strip costs one pass
/// over its bytes and no regular expression (`home_list_first_screen`,
/// cmux-next-ios/design/instant-perf.md).
func plainPreview(_ markdown: String) -> String {
    MessagePreview(markdown: markdown).text(.chief)
}

extension MessagePreview.Words {
    /// The preview words in the app's language, looked up once: every Home row asks for them, and the
    /// app's language only changes with a relaunch.
    static let chief: MessagePreview.Words = {
        MessagePreview.Words(
            table: { String(format: String(localized: "mobile.chief.preview.table", defaultValue: "Table: %@", bundle: .module), $0) },
            untitledTable: String(localized: "mobile.chief.preview.tableUntitled", defaultValue: "Table", bundle: .module),
            image: String(localized: "mobile.chief.preview.image", defaultValue: "Image", bundle: .module),
            images: { String(format: String(localized: "mobile.chief.preview.images", defaultValue: "%lld images", bundle: .module), $0) }
        )
    }()
}
