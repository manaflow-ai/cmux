import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Testing

/// Theme sweep 3, batch B: Home's sheets (New Message, Invite, New Chief) sat on the sheet
/// window's system background, and their fields, the New Message search field and the Chief
/// settings' name field drew AppKit's bezel, text and gray placeholder. Under a
/// purple room theme every field draws the theme. The sheets then painted the theme's solid popup
/// surface until Leo, 2026-10-21: "glass is never opaque (the only exception is the Reduce
/// Transparency fallback)". They sit on this Mac's overlay glass now, as the Share dialog does (#24048).
@MainActor @Suite(.serialized) struct HomeSheetThemeTests {
    @Test func homeSheetsAreGlassUnlessReduceTransparency() throws {
        let scope = try ThemedOverlayColorsTests.purpleRoom()
        let system = OverlayMaterial.select(liquidGlassAvailable: Glass.isLiquidGlassAvailable,
                                            reduceTransparency: ReduceTransparency.shared.isEnabled)
        let sheets: [HomeSheetController] = [HomeInviteSheet(pending: []), HomeNewChiefSheet()]
        let info = HomeGroupInfoSheet(model: Self.groupInfoModel(), colors: HomeGroupInfoColors())
        let surfaces: [(String, NSView, OverlaySurfaceView)] = sheets.map { ("\(type(of: $0))", $0.view, $0.surface) }
            + [("HomeGroupInfoSheet", info.view, info.surface)]
        for (name, root, glass) in surfaces {
            scope.root(root)
            #expect((root.layer?.backgroundColor?.alpha ?? 0) == 0, "\(name) paints no solid fill over its glass")
            #expect(root.subviews.first === glass, "\(name): the glass sits under the content")
            #expect(glass.materialOverride == nil && !glass.isCard, "\(name) follows this Mac's material")
            #expect(glass.material == system, "\(name): \(glass.material) vs \(system)")
            #expect(glass.samplesBehindWindow, "\(name)'s vibrancy blurs the window behind the sheet")
        }
        // New Message's suggestion list (a page now, no sheet) floats over the page on the shared
        // overlay glass, not the solid popup surface (Leo 2026-10-21: "STOP DOING SOLID").
        let suggestions = HomeRecipientSuggestionsView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        scope.root(suggestions)
        suggestions.applyColors()
        #expect((suggestions.table.backgroundColor.usingColorSpace(.sRGB)?.alphaComponent ?? 1) < 0.01)
        #expect(suggestions.scroll.borderType == .noBorder)
        #expect((suggestions.layer?.backgroundColor?.alpha ?? 0) == 0, "the list paints a fill over its glass")
        #expect(suggestions.subviews.first === suggestions.glass, "the glass sits under the rows")
        #expect(!suggestions.glass.isCard && suggestions.glass.frame == suggestions.bounds)
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

    static func groupInfoModel() -> HomeGroupInfoModel {
        let info = HomeGroupInfo(conversation: ConversationID("a"), isGroup: true, title: "A", displayTitle: "A", members: [],
                                 canMute: true, muted: false)
        return HomeGroupInfoModel(info: info, addable: [], actions: HomeGroupInfoActions(
            rename: { _ in .done }, add: { _, _ in .done }, remove: { _ in .done }, setMuted: { _ in .done },
            leave: {}, inviteByEmail: {}, setChiefReplies: { _ in .done }))
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
    func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot { throw .localUnreachable }
}
