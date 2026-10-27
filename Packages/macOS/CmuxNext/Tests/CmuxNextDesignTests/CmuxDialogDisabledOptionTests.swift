import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// A dialog's choice list can show an option greyed out (Move Chief To…: an offline host, a paired
/// server that is not a move target yet): the option is listed, cannot be picked, and the list
/// starts on the first option that can.
@MainActor
struct CmuxDialogDisabledOptionTests {
    private static let spec = CmuxDialogSpec(title: "Move Chief to", fields: [.choice(id: "choice", label: nil, options: [
        CmuxDialogOption(label: "mini — offline", value: "mini", isEnabled: false),
        CmuxDialogOption(label: "This Mac", value: "local"),
    ], selected: nil)], buttons: [.ok("Select")])

    @Test func aDisabledOptionIsListedButGreyedOut() throws {
        let popup = try #require(Self.find(CmuxDialogView(spec: Self.spec), id: "cmux.dialog.field.choice") as? NSPopUpButton)
        #expect(popup.numberOfItems == 2)
        #expect(popup.autoenablesItems == false)
        #expect(popup.item(at: 0)?.isEnabled == false)
        #expect(popup.item(at: 1)?.isEnabled == true)
        #expect(popup.selectedItem?.representedObject as? String == "local", "starts on the first option that can be picked")
    }

    private static func find(_ view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for subview in view.subviews {
            if let match = find(subview, id: id) { return match }
        }
        return nil
    }
}
