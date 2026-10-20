import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Testing

/// Theme sweep 3, batch B: Home's sheets (New Message, Invite, New Chief) sat on the sheet
/// window's system background, and their fields, the New Message search field and the Chief
/// settings' name field drew AppKit's bezel, text and gray placeholder. Under a
/// purple room theme the sheets paint the theme's popup surface and every field draws the theme.
@MainActor @Suite(.serialized) struct HomeSheetThemeTests {
    @Test func homeSheetsPaintThePopupSurface() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let surface = scope.perform { Palette.popupSurface }
        let sheets: [HomeSheetController] = [HomeInviteSheet(pending: []), HomeNewChiefSheet()]
        for sheet in sheets {
            scope.root(sheet.view)
            let fill = try #require(sheet.view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
                                    "\(type(of: sheet)) paints a surface over the system sheet background")
            #expect(ThemedOverlayColorsTests.same(fill, surface), "\(type(of: sheet)): \(fill) vs \(surface)")
        }
        // New Message's suggestion list (a page now, no sheet) lets the popup surface show.
        let suggestions = HomeRecipientSuggestionsView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        scope.root(suggestions)
        suggestions.applyColors()
        #expect((suggestions.table.backgroundColor.usingColorSpace(.sRGB)?.alphaComponent ?? 1) < 0.01)
        #expect(suggestions.scroll.borderType == .noBorder)
        let list = try #require(suggestions.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(ThemedOverlayColorsTests.same(list, surface))
    }

    @Test func homeFieldsDrawTheThemeNotTheSystemBezel() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let roots: [NSView] = [
            HomeInviteSheet(pending: []).view, HomeNewChiefSheet().view,
            HomeChiefSettingsView(muxHome: FileManager.default.temporaryDirectory, source: OfflineEngine()),
        ]
        let ink = scope.perform { Palette.textPrimary }
        let hint = scope.perform { Palette.textTertiary }
        var fields: [NSTextField] = []
        for root in roots {
            scope.root(root)
            fields += Self.editableFields(in: root)
        }
        // Invite: email; New Chief: name; Chief settings: name.
        #expect(fields.count >= 3)
        for field in fields {
            let name = field.accessibilityLabel() ?? "\(type(of: field))"
            #expect(!field.isBezeled && !field.drawsBackground, "\(name): AppKit's bezel and fill are gone")
            #expect(!(field is NSSearchField), "\(name): no system search field bezel")
            #expect(field.textColor.map { ThemedOverlayColorsTests.same($0, ink) } == true, "\(name): text in the theme ink")
            let placeholder = field.placeholderAttributedString.flatMap { text in
                text.length > 0 ? text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
            }
            #expect(placeholder.map { ThemedOverlayColorsTests.same($0, hint) } == true, "\(name): placeholder in the theme hint ink")
        }
    }

    static func editableFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField, field.isEditable { found.append(field) }
        for subview in view.subviews { found += editableFields(in: subview) }
        return found
    }
}

/// A Chief whose brain is not running.
private struct OfflineEngine: HomeChiefEngineSource {
    var isLocal: Bool { true }
    var place: String? { nil }
    func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
    func set(_ key: String, _ value: String?) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
}
