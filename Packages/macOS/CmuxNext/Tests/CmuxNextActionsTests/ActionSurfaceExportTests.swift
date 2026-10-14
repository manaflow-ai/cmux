@testable import CmuxNextActions
import Foundation
import Testing

/// What other clients read from plans/cmux-next/action-surfaces.json
/// (`ActionSurfaceExport.json`): the menu bar placement of each action,
/// the right-click menus by the names people know them by, and the
/// hand-built menus that the export leaves out, each naming the file that
/// builds it.
@MainActor
@Suite struct ActionSurfaceExportTests {
    let catalog = ActionCatalog.all

    func exportRoot() throws -> [String: Any] {
        let text = ActionSurfaceExport.json(catalog)
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func actionRows() throws -> [String: [String: Any]] {
        let actions = try #require(try exportRoot()["actions"] as? [[String: Any]])
        var rows: [String: [String: Any]] = [:]
        for row in actions {
            if let id = row["id"] as? String { rows[id] = row }
        }
        return rows
    }

    /// Settings… is in the app menu; an action with no menu bar placement
    /// still carries the field, as null.
    @Test func everyActionNamesItsMenuBarMenu() throws {
        let rows = try actionRows()
        #expect(rows["openSettings"]?["main_menu"] as? String == ActionMainMenu.app.rawValue)
        for descriptor in catalog {
            let row = try #require(rows[descriptor.id.rawValue], "\(descriptor.id) is not exported")
            let value = try #require(row["main_menu"], "\(descriptor.id) has no main_menu")
            if let menu = descriptor.mainMenu {
                #expect(value as? String == menu.rawValue, "\(descriptor.id)")
            } else {
                #expect(value is NSNull, "\(descriptor.id) has no menu bar menu but exports \(value)")
            }
        }
    }

    /// The Space chip's right-click menu is exported as `space`, both as a
    /// menu and in each of its actions' `context_menus`.
    @Test func spaceChipMenuIsNamedSpace() throws {
        let menus = try #require(try exportRoot()["context_menus"] as? [String: Any])
        #expect(menus["space"] != nil)
        #expect(menus["profile"] == nil)
        let rename = try #require(try actionRows()["space.rename"])
        let contexts = try #require(rename["context_menus"] as? [String])
        #expect(contexts.contains("space"))
        #expect(!contexts.contains("profile"))
    }

    /// Every hand-built menu the export leaves out names a source file that
    /// still exists (relative to Packages/macOS/CmuxNext/Sources), once.
    @Test func everyHandBuiltMenuNamesAnExistingSource() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let entries = try #require(try exportRoot()["context_menus_not_exported"] as? [[String: String]])
        #expect(!entries.isEmpty)
        var names: Set<String> = []
        for entry in entries {
            let name = try #require(entry["name"])
            let source = try #require(entry["source"], "\(name) names no source")
            #expect(names.insert(name).inserted, "\(name) is listed twice")
            #expect(FileManager.default.fileExists(atPath: sources.appendingPathComponent(source).path),
                    "\(name): \(source) does not exist")
        }
    }
}
