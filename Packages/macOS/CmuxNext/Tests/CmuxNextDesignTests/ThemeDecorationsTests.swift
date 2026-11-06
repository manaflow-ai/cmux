@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Foundation
import JavaScriptCore
import Testing

/// The theme's personality slots (ThemeDecorations): the Updated card's doodle reaches pages with the
/// theme, as `data-cmux-decoration-updated-card="doodle"` on `<html>`, only while its Debug toggle is
/// on. Off (the default), the payload has no `decorations` key, so pages get what they got before.
@MainActor @Suite(.serialized) struct ThemeDecorationsTests {
    private static func payload() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(WebTheme(.unresolved).payloadJSON.utf8)) as? [String: Any])
    }

    private static func setDoodle(_ on: Bool?) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(ThemeDecorations.tunables)
        TunableStore.shared.set(ThemeDecorations.updateDoodle.key, on.map(TunableValue.bool))
    }

    @Test func offByDefaultSendsNoDecorations() throws {
        Self.setDoodle(nil)
        defer { Self.setDoodle(nil) }
        #expect(ThemeDecorations.updateDoodle.descriptor.defaultValue == .bool(false))
        #expect(ThemeDecorations.current == ThemeDecorations())
        #expect(try Self.payload()["decorations"] == nil)
    }

    @Test func theToggleFillsTheUpdatedCardSlot() throws {
        Self.setDoodle(true)
        defer { Self.setDoodle(nil) }
        #expect(ThemeDecorations.current.filled == [.updatedCard: "doodle"])
        #expect(try Self.payload()["decorations"] as? [String: String] == ["updated-card": "doodle"])
    }

    @Test func theToggleIsADebugTunable() {
        #expect(DesignTunables.all.contains { $0.key == ThemeDecorations.updateDoodle.key })
    }

    /// The bootstrap writes each filled slot as an attribute and drops a slot the next theme leaves
    /// empty: turning the toggle off takes the doodle away without a reload.
    @Test func theBootstrapSetsAndClearsTheSlotAttribute() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var attrs = {};
        var root = { style: { setProperty: function () {}, colorScheme: '' }, appendChild: function () {},
          setAttribute: function (k, v) { attrs[k] = String(v); }, removeAttribute: function (k) { delete attrs[k]; },
          getAttribute: function (k) { return k in attrs ? attrs[k] : null; } };
        var document = { documentElement: root, head: { appendChild: function () {} }, createElement: function () { return {}; } };
        var window = this;
        window.dispatchEvent = function () {};
        function CustomEvent(type) { this.type = type; }
        """)
        context.evaluateScript(WebTheme.bootstrapScript)
        let slot = "data-cmux-decoration-updated-card"
        context.evaluateScript("window.cmuxTheme.apply({variables: {}, colorScheme: 'dark', decorations: {'updated-card': 'doodle'}})")
        #expect(context.evaluateScript("attrs['\(slot)']")?.toString() == "doodle")
        context.evaluateScript("window.cmuxTheme.apply({variables: {}, colorScheme: 'dark'})")
        #expect(context.evaluateScript("'\(slot)' in attrs")?.toBool() == false)
        #expect(context.exception == nil)
    }
}
