import AppKit
@testable import CmuxNextActions
import Foundation
import Testing

/// The palette and the context menus share one vocabulary (ContextMenuShapeTests holds the menu
/// side): a toggle reads "Pin/Unpin", and taking off an icon or color reads "Remove", so a row
/// the menu shows as "Remove Icon" is "Remove Space Icon" in the palette, not "Clear Space Icon".
struct PaletteMenuVocabularyTests {
    @Test func paletteTitlesUseTheMenusWords() throws {
        let orToggle = try NSRegularExpression(pattern: #"(?:^|: )\w+ or \w+ "#)
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

    /// The toggle style holds for every action, not only the palette's: a keyboard-only action's
    /// title shows in Keyboard Shortcuts settings ("Pin or Unpin Chat" drifted there unseen), and a
    /// prefixed title holds it after its prefix ("Palette: Show/Hide Actions").
    @Test func everyActionTitleUsesOneToggleStyle() throws {
        let orToggle = try NSRegularExpression(pattern: #"(?:^|: )\w+ or \w+ "#)
        for descriptor in ActionCatalog.all {
            let title = descriptor.title
            #expect(orToggle.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) == nil,
                    "\(descriptor.id) \(title): a toggle reads X/Y")
            #expect(!title.hasPrefix("Toggle Group"), "\(descriptor.id) \(title): a toggle reads X/Y")
        }
    }

    /// Palette titles are menu titles, so they follow the macOS title style: the ellipsis is one
    /// character ("…", never "..."), and every word is capitalized except a short article,
    /// conjunction or preposition inside the title ("Move Tab to Workspace…"). The first and last
    /// words are always capitalized ("Move Chief To…", "Swap with Session…"); cmux and acpmux keep their case.
    @Test func paletteTitlesUseTitleCase() {
        let minor: Set<String> = ["a", "an", "the", "and", "or", "nor", "but", "to", "in", "on", "of",
                                  "for", "by", "at", "as", "from", "with", "into", "onto", "via", "vs", "per"]
        let brands = ["cmux", "acpmux", "iPhone", "iPad", "iOS", "macOS"]
        let trim = CharacterSet(charactersIn: "()\"“”,:.")
        for descriptor in ActionCatalog.all where descriptor.isPaletteVisible {
            let title = descriptor.title
            #expect(!title.contains("..."), "\(descriptor.id) \(title): the ellipsis is one character, …")
            // This chooser's requested product copy ends in a lowercase preposition.
            if descriptor.id == "palette.newAgentChatOn", title == "New Agent Chat on…" { continue }
            let words = title.replacingOccurrences(of: "…", with: "").split(separator: " ")
            for (index, word) in words.enumerated() {
                for part in word.split(separator: "/") {
                    let core = part.trimmingCharacters(in: trim)
                    guard let first = core.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first),
                          !brands.contains(where: { core.hasPrefix($0) }) else { continue }
                    let inside = index > 0 && index < words.count - 1
                    #expect(inside && minor.contains(core), "\(descriptor.id) \(title): \(core) is capitalized")
                }
            }
        }
    }

    /// A title ends in "…" exactly when choosing it asks for more first. A phone action with a
    /// required argument (a URL, text, a point, a button or a locale) makes the palette ask for it
    /// (`ActionRegistry.argumentCollector`); one without (Boot, Rotate, Take Screenshot) runs at once.
    @Test func phoneTitlesEndInAnEllipsisExactlyWhenTheyAsk() {
        let phones = ActionCatalog.all.filter { $0.id.rawValue.hasPrefix("phone.") }
        #expect(!phones.isEmpty)
        for descriptor in phones {
            let asks = descriptor.arguments.contains(where: \.isRequired)
            #expect(descriptor.title.hasSuffix("…") == asks,
                    "\(descriptor.id) \(descriptor.title): \(asks ? "asks for input, so it ends in …" : "acts at once, so no …")")
        }
    }

    /// The same rule outside the Phone family, for the rows the palette audit found wrong. Each of
    /// the first list has a required argument the palette collects before it runs (a time range and
    /// profile, a history entry, an app, a team, a host address, a Priority chat). Cloud Diagnostics
    /// shows its result in a toast and Edit Group Config opens cmux-next.json, as Open cmux-next.json
    /// does: neither asks, so neither ends in "…".
    @Test func auditedTitlesEndInAnEllipsisExactlyWhenTheyAsk() throws {
        let byID = Dictionary(ActionCatalog.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let asking: [ActionID] = ["palette.browserClearHistory", "history.open", "app.hide", "app.unhide",
                                  "openTeamPicker", "remote.openBrowserTab",
                                  // The Priority row actions ask which chat (a hover button or the row's menu names it).
                                  "sidebar.priority.markRead", "sidebar.priority.togglePin", "sidebar.priority.snooze"]
        for id in asking {
            let descriptor = try #require(byID[id], "\(id)")
            let asks = descriptor.arguments.contains(where: \.isRequired)
            #expect(asks, "\(id) no longer asks for input")
            #expect(descriptor.title.hasSuffix("…"), "\(id) \(descriptor.title): asks for input, so it ends in …")
        }
        for id: ActionID in ["cloudDiagnostics", "workspaceGroup.editConfig"] {
            let descriptor = try #require(byID[id], "\(id)")
            let asks = descriptor.arguments.contains(where: \.isRequired)
            #expect(!asks, "\(id) now asks for input")
            #expect(!descriptor.title.hasSuffix("…"), "\(id) \(descriptor.title): acts at once, so no …")
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

    /// The palette shows a group close out of context, so its title names the group's noun. The
    /// context menus may keep "Close Group": there the right-clicked row names it.
    @Test func groupCloseTitlesNameTheirNoun() throws {
        let byID = Dictionary(ActionCatalog.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let titles: [ActionID: String] = [
            "tabGroup.close": "Close Tab Group",
            "screenGroup.close": "Close Screen Group",
            "workspaceGroup.closeWorkspaces": "Close Workspaces in Group",
        ]
        for (id, title) in titles {
            #expect(try #require(byID[id], "\(id)").title == title, "\(id)")
        }
    }

    /// One name per command: no two palette or menu bar actions share a name unless one is a
    /// declared duplicate of the other (`ActionDescriptor.paletteDuplicates`), and a duplicate
    /// carries its canonical action's name. Two different commands that read alike ("Show Feed"
    /// for the right sidebar's mode and for the feed panel) fail here.
    @Test func everyNameBelongsToOneCommand() throws {
        func key(_ title: String) -> String {
            (title.hasSuffix("…") ? String(title.dropLast()) : title).lowercased()
        }
        let shown = ActionCatalog.all.filter { $0.isPaletteVisible || $0.mainMenu != nil }
        let byName = Dictionary(grouping: shown) { key($0.title) }
        for (name, descriptors) in byName.sorted(by: { $0.key < $1.key }) where descriptors.count > 1 {
            let commands = Set(descriptors.map(\.canonicalActionID))
            #expect(commands.count == 1, "\(name): \(descriptors.map(\.id.rawValue).sorted()) are different commands with one name")
        }
        let byID = Dictionary(ActionCatalog.all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (duplicate, canonical) in ActionDescriptor.paletteDuplicates {
            let copy = try #require(byID[duplicate], "\(duplicate)")
            let original = try #require(byID[canonical], "\(canonical)")
            #expect(key(copy.title) == key(original.title), "\(duplicate) reads \(copy.title), not \(original.title)")
            #expect(original.canonicalActionID == canonical, "\(canonical) is itself a duplicate")
        }
    }

    /// The menu bar reads each action's name from the catalog, never a string of its own: every
    /// item an action's descriptor places in a menu carries that descriptor's title.
    @Test func menuBarItemsUseTheCatalogName() throws {
        let registry = ActionRegistry.standard()
        for menu in ActionMainMenu.allCases {
            let items = registry.makeMainMenuItems(for: menu).filter { !$0.isSeparatorItem }
            let placed = registry.descriptors.filter { $0.mainMenu == menu }
            #expect(items.count == placed.count, "\(menu): \(items.count) items for \(placed.count) actions")
            for (item, descriptor) in zip(items, placed) {
                #expect(item.title == descriptor.title, "\(menu) \(descriptor.id) reads \(item.title), not \(descriptor.title)")
            }
        }
    }
}
