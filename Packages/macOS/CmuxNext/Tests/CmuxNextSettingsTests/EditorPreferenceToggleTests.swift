import CmuxNextSettings
import Testing

/// The code editor page's toggles (PAGE-PREFS): Opt-Z's word wrap and the palette's Toggle Editor
/// Minimap flip the settings the page toolbar writes.
struct EditorPreferenceToggleTests {
    @Test func minimapFlipsEitherForm() {
        let minimap = EditorPreferenceToggle.minimap
        #expect(minimap.key == "editor.minimap.enabled")
        #expect(minimap.next(in: nil) == .bool(true))
        #expect(minimap.next(in: .object(["minimap": .bool(true)])) == .bool(false))
        #expect(minimap.next(in: .object(["minimap": .object(["enabled": .bool(true)])])) == .bool(false))
        #expect(minimap.next(in: .object(["minimap": .object(["enabled": .bool(false)])])) == .bool(true))
    }

    @Test func wordWrapFlipsOffAndOn() {
        let wrap = EditorPreferenceToggle.wordWrap
        #expect(wrap.key == "editor.wordWrap")
        #expect(wrap.next(in: nil) == .string("on"))
        #expect(wrap.next(in: .object(["wordWrap": .string("on")])) == .string("off"))
        #expect(wrap.next(in: .object(["wordWrap": .string("bounded")])) == .string("off"))
    }

    @Test func eachToggleIsACatalogAction() {
        #expect(EditorPreferenceToggle.all.map(\.action) == ["toggleFileEditorWordWrap", "toggleFileEditorMinimap"])
    }
}
