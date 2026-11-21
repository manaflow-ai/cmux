import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// A dialog's choice list can show an option greyed out (Move Chief To…: an offline host, a paired
/// server that is not a move target yet): the option is listed, cannot be picked, and the list
/// starts on the first option that can. The overlay page draws the list from the spec; this guards
/// the dialog's own values, which are what the center answers with.
@MainActor
struct CmuxDialogDisabledOptionTests {
    private static let spec = CmuxDialogSpec(title: "Move Chief to", fields: [.choice(id: "choice", label: nil, options: [
        CmuxDialogOption(label: "mini — offline", value: "mini", isEnabled: false),
        CmuxDialogOption(label: "This Mac", value: "local"),
    ], selected: nil)], buttons: [.ok("Select")])

    @Test func aDisabledOptionIsNeverTheSelection() {
        let dialog = CmuxDialogPresentation(id: 1, spec: Self.spec, activeLook: nil)
        #expect(dialog.values["choice"] == .text("local"), "starts on the first option that can be picked")
        #expect(!dialog.setValue(.text("mini"), for: "choice"), "automation picked a disabled option")
        dialog.edited(["choice": .text("mini")])
        #expect(dialog.values["choice"] == .text("local"), "an edit picked a disabled option")
    }

    /// A spec that names the disabled option as selected still starts on one that can be picked.
    @Test func aDisabledSelectedOptionStartsOnTheFirstEnabledOne() {
        let spec = CmuxDialogSpec(title: "Move Chief to", fields: [.choice(id: "choice", label: nil, options: [
            CmuxDialogOption(label: "mini — offline", value: "mini", isEnabled: false),
            CmuxDialogOption(label: "This Mac", value: "local"),
        ], selected: "mini")], buttons: [.ok("Select")])
        #expect(CmuxDialogPresentation.initialValues(spec)["choice"] == .text("local"))
    }
}
