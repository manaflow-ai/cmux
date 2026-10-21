@testable import CmuxNextActions
import Foundation
import Testing

/// The palette and the context menus share one vocabulary (ContextMenuShapeTests holds the menu
/// side): a toggle reads "Pin/Unpin", and taking off an icon or color reads "Remove", so a row
/// the menu shows as "Remove Icon" is "Remove Space Icon" in the palette, not "Clear Space Icon".
struct PaletteMenuVocabularyTests {
    @Test func paletteTitlesUseTheMenusWords() throws {
        let orToggle = try NSRegularExpression(pattern: #"^\w+ or \w+ "#)
        let clear = try NSRegularExpression(pattern: #"^Clear .*\b(Icon|Color)$"#)
        func matches(_ regex: NSRegularExpression, _ title: String) -> Bool {
            regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
        }
        for descriptor in ActionCatalog.all where descriptor.isPaletteVisible {
            let title = descriptor.title
            #expect(!matches(orToggle, title), "\(descriptor.id) \(title): a toggle reads X/Y")
            #expect(!title.hasPrefix("Toggle Group"), "\(descriptor.id) \(title): a toggle reads X/Y")
            #expect(!matches(clear, title), "\(descriptor.id) \(title): an icon or color is removed, as in the menus")
            #expect(title != "Hide", "\(descriptor.id): the palette names what Hide hides")
        }
    }

    /// A renamed row still answers the word it used to start with.
    @Test func renamedRowsKeepTheirOldWord() throws {
        let byID = Dictionary(ActionCatalog.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id: ActionID in ["space.clearIcon", "space.clearColor", "workspace.clearIcon",
                             "browserProfile.clearIcon", "browserProfile.clearColor"] {
            #expect(try #require(byID[id]).keywords.contains("clear"), "\(id)")
        }
        #expect(try #require(byID["toggleFocusedWorkspaceGroupCollapsed"]).keywords.contains("toggle"))
    }
}
