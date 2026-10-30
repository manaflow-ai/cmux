import AppKit
@testable import CmuxNextDesign
import Testing

/// A checked box draws the theme, never macOS's blue (cx-wqn5): a dialog's checkbox fills with
/// the theme's ink, as onboarding's do, not the system accent.
@MainActor
struct ThemedCheckboxTests {
    @Test func aDialogCheckboxIsFilledWithTheThemeNotTheAccent() throws {
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "Open Link", fields: [.check(id: "always", title: "Always", on: true)],
                                                                buttons: [.ok("Open")]))
        let check = try #require(Self.find(dialog, id: "cmux.dialog.field.always") as? NSButton)
        #expect(check.state == .on)
        let fill = try #require(check.bezelColor?.usingColorSpace(.sRGB))
        let channels = [fill.redComponent, fill.greenComponent, fill.blueComponent]
        #expect(channels.max()! - channels.min()! < 0.08)
    }

    private static func find(_ view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for subview in view.subviews {
            if let match = find(subview, id: id) { return match }
        }
        return nil
    }
}
