import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing

/// A right-click menu cmux builds carries none of AppKit's own rows. On macOS 27 AppKit put an "Ask Siri"
/// field on top of every context menu that allows plugins and has a row titled "Copy" (the tab and
/// workspace menus' Copy folder); Leo 2026-11-22: "there is now an ask siri. which is weird. in the tab."
/// `NSMenu.withoutSystemItems()` turns off plugins (Services and that trigger), Writing Tools and the
/// assistant field; every way a cmux view hands AppKit a right-click menu goes through it.
@MainActor @Suite struct ContextMenuSystemItemsTests {
    @Test func aMenuWithoutSystemItemsAllowsNone() {
        _ = NSApplication.shared
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
        #expect(menu.allowsSystemItems, "AppKit's default lets it add rows; this test needs that to mean something")
        let returned = menu.withoutSystemItems()
        #expect(returned === menu)
        #expect(!menu.allowsContextMenuPlugIns)
        if #available(macOS 15.2, *) { #expect(!menu.automaticallyInsertsWritingToolsItems) }
        #expect(!menu.allowsSystemItems)
        #expect(NSMenu.withoutSystemItems(nil) == nil)
    }

    /// AppKit's own check, on a macOS that has the "Ask Siri" field (27 and later; skipped before): the
    /// field AppKit puts first in a context menu shows for a menu with a "Copy" row, and stays hidden once
    /// the menu drops system items.
    @Test func appKitHidesTheAskSiriFieldOnAMenuWithoutSystemItems() {
        _ = NSApplication.shared
        let validate = NSSelectorFromString("_validateAssistantFieldPresenceBeforePresentingMenu")
        guard let fieldClass = NSClassFromString("NSCampoMenuItem") as? NSMenuItem.Type, NSMenu.instancesRespond(to: validate) else { return }
        func fieldShows(droppingSystemItems: Bool) -> Bool {
            let menu = NSMenu()
            let field = fieldClass.init(title: "", action: nil, keyEquivalent: "")
            menu.addItem(field)
            menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
            if droppingSystemItems { menu.withoutSystemItems() }
            _ = menu.perform(validate)
            return !field.isHidden
        }
        // An AppKit that no longer shows the field for a Copy row leaves nothing to check.
        guard fieldShows(droppingSystemItems: false) else { return }
        #expect(!fieldShows(droppingSystemItems: true))
    }

    @Test func themingAMenuDropsSystemItems() {
        _ = NSApplication.shared
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: nil, keyEquivalent: ""))
        menu.themeRows(in: ThemeScope(level: .room))
        #expect(!menu.allowsSystemItems)
    }

    /// Every `menu(for:)` override and `popUpContextMenu` call under Packages/ hands AppKit its menu through
    /// `withoutSystemItems` (or a package's own `systemFree`, where CmuxNextDesign is not linked). A text
    /// view that returns the system's own text menu is listed in `systemTextMenus` with its reason.
    @Test func everyRightClickMenuDropsSystemItems() throws {
        let packages = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: packages.appendingPathComponent("macOS/CmuxNext/Package.swift").path))
        let systemTextMenus: [String: String] = [
            "MacBubbleTextView.swift": "a sent bubble's text menu: the system's Look Up, Translate and Services on selected text",
            "MacComposerView.swift": "the composer's text menu: the system's editing menu with two rows added",
        ]
        let drops = ["withoutSystemItems", "systemFree"]
        var findings: [String] = []
        var seenAllowlisted: Set<String> = []
        let files = FileManager.default.enumerator(at: packages, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.path.contains("/Sources/") && !$0.path.contains("/.build/") } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("func menu(for event: NSEvent) -> NSMenu?") || text.contains("popUpContextMenu(") else { continue }
            let name = file.lastPathComponent
            let path = file.path.replacingOccurrences(of: packages.path + "/", with: "")
            for body in Self.bodies(of: "override func menu(for event: NSEvent) -> NSMenu?", in: text) {
                if systemTextMenus[name] != nil { seenAllowlisted.insert(name); continue }
                if !drops.contains(where: body.contains) {
                    findings.append("\(path): menu(for:) returns a menu without withoutSystemItems")
                }
            }
            for line in text.split(separator: "\n") where line.contains("popUpContextMenu(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                if !drops.contains(where: line.contains) {
                    findings.append("\(path): popUpContextMenu without withoutSystemItems: \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(findings.isEmpty, "\(findings.joined(separator: "\n"))")
        #expect(seenAllowlisted == Set(systemTextMenus.keys), "an allowlisted text view no longer overrides menu(for:): drop it from systemTextMenus")
    }

    /// The text of each function body that starts with `signature`, braces matched.
    static func bodies(of signature: String, in text: String) -> [Substring] {
        var result: [Substring] = []
        var search = text.startIndex
        while let range = text.range(of: signature, range: search..<text.endIndex) {
            guard let open = text[range.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 } else if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                index = text.index(after: index)
            }
            result.append(text[open..<min(index, text.endIndex)])
            search = index < text.endIndex ? text.index(after: index) : text.endIndex
        }
        return result
    }
}
