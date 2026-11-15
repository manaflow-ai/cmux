import AppKit
import CmuxNextDesignTokens
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// "Quit cmux?" as a native alert draws it (Leo, 2026-11-03: "aren't these all kinda awkward looking", on four
/// card-wide slabs, two of them loud pink, and a stray Escape glyph): Cancel and the default on one line, the default
/// rightmost; the destructive choices as quiet red text on their own line under them, never card-wide and never
/// filled at rest; "Don't ask again" last; no key glyphs, while Return and Escape still answer. The overlay page
/// draws the card (``CmuxDialogView``); this guards the spec's layout, keys and quiet look.
@MainActor
struct CmuxDialogSafeDefaultLayoutTests {
    private static let spec = CmuxDialogSpec(
        title: "Quit cmux?", lines: ["Keeping sessions leaves your terminals and agents running for next time."],
        fields: [.check(id: "remember", title: "Don’t ask again", on: false)],
        buttons: [
            CmuxDialogButton(id: "end-keep-layout", title: "End Sessions, Keep Layout", role: .destructive),
            CmuxDialogButton(id: "end-everything", title: "End Everything", role: .destructive),
            CmuxDialogButton(id: "cancel", title: "Cancel", role: .cancel),
            CmuxDialogButton(id: "keep", title: "Keep Sessions Running", role: .default),
        ],
        layout: .safeDefault)

    @Test func aDialogWithADestructiveChoiceTakesTheAlertLayout() {
        #expect(CmuxDialogSpec.Layout(alertFor: Self.spec.buttons) == .safeDefault)
        #expect(CmuxDialogSpec.Layout(alertFor: Self.spec.buttons.filter { $0.role != .destructive }) == .standard)
    }

    /// Hiding a shortcut's visual decoration must not hide its accessibility help (#33235).
    @Test(arguments: [CmuxDialogSpec.Layout.safeDefault, .standard])
    func keyHelpSurvivesTheLayoutAndReturnAndEscapeStillAnswer(_ layout: CmuxDialogSpec.Layout) {
        var spec = Self.spec
        spec.layout = layout
        let dialog = CmuxDialogPresentation(id: 1, spec: spec, activeLook: nil)
        let card = CmuxDialogView(dialog: dialog)
        #expect(card.buttonViews.count == spec.buttons.count)
        let help = ["keep": "Return", "cancel": "Escape"]
        for view in card.buttonViews {
            #expect(view.accessibilityLabel() == view.button.title)
            #expect(view.accessibilityHelp() == help[view.button.id])
            #expect(view.attributedTitle.string == view.button.title)
            let hasKeycap = view.subviews.contains { $0 is CmuxDialogKeycapView }
            #expect(hasKeycap == (layout == .standard && help[view.button.id] != nil))
            view.retitle("Updated \(view.button.title)")
            #expect(view.accessibilityLabel() == view.button.title)
            #expect(view.accessibilityHelp() == help[view.button.id])
            #expect(view.attributedTitle.string == view.button.title)
        }
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        #expect(dialog.handle(.return, modifiers: []))
        #expect(dialog.handle(.escape, modifiers: []))
        #expect(pressed == ["keep", "cancel"])
    }

    /// A quiet destructive title reads at 4.5:1 on the card, light and dark, in every state.
    @Test func aQuietDestructiveTitleReadsOnTheCard() {
        for input in [ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F)),
                      ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6))] {
            let tokens = ThemeTokens.derive(from: input)
            for state in CmuxDialogButtonLook.State.allCases {
                let look = CmuxDialogButtonLook(role: .destructive, tokens: tokens, state: state, quiet: true)
                for surface in look.surfaces {
                    #expect(look.title.contrast(with: surface) >= 4.5, "\(state): \(look.title.contrast(with: surface)):1")
                }
            }
        }
    }
}
