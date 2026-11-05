import AppKit
import CmuxNextDesignTokens
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// "Quit cmux?" as a native alert draws it (Leo, 2026-11-03: "aren't these all kinda awkward looking", on four
/// card-wide slabs, two of them loud pink, and a stray Escape glyph): Cancel and the default on one line, the default
/// rightmost; the destructive choices as quiet red text on their own line under them, never card-wide and never
/// filled at rest; "Don't ask again" last; no key glyphs, while Return and Escape still answer.
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

    private static func frames(_ view: CmuxDialogView) -> [String: NSRect] {
        Dictionary(uniqueKeysWithValues: view.buttonViews.map { ($0.button.id, $0.convert($0.bounds, to: view)) })
    }

    @Test func aDialogWithADestructiveChoiceTakesTheAlertLayout() {
        #expect(CmuxDialogSpec.Layout(alertFor: Self.spec.buttons) == .safeDefault)
        #expect(CmuxDialogSpec.Layout(alertFor: Self.spec.buttons.filter { $0.role != .destructive }) == .standard)
    }

    @Test func cancelAndTheDefaultShareALineAndTheEndChoicesAreQuietUnderThem() throws {
        let view = CmuxDialogView(spec: Self.spec)
        view.layoutSubtreeIfNeeded()
        let frames = Self.frames(view)
        let keep = try #require(frames["keep"]), cancel = try #require(frames["cancel"])
        let endLayout = try #require(frames["end-keep-layout"]), endAll = try #require(frames["end-everything"])
        #expect(abs(keep.midY - cancel.midY) < 0.5, "Cancel and Keep Sessions Running are not on one line")
        #expect(keep.minX > cancel.maxX, "the default is not right of Cancel")
        // AppKit: y grows upward, so "under" is a smaller maxY.
        #expect(endLayout.maxY <= cancel.minY && endAll.maxY <= cancel.minY, "an end choice is not under the main line")
        let contentWidth = view.bounds.width - CmuxDialogMetrics.padding * 2
        for (id, frame) in [("end-keep-layout", endLayout), ("end-everything", endAll)] {
            #expect(frame.width < contentWidth - 1, "\(id) is a card-wide slab")
            #expect(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(id) is outside the card")
        }
        for button in view.buttonViews {
            #expect(button.keyHint == nil, "\(button.button.id) draws a key glyph")
            #expect(button.isQuiet == (button.button.role == .destructive))
            if button.isQuiet { #expect(button.look.fill.alpha == 0, "\(button.button.id) is filled at rest") }
        }
        // Return and Escape still answer.
        #expect(CmuxDialogKeys.action(for: .return, modifiers: [], in: Self.spec) == .press("keep"))
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: Self.spec) == .press("cancel"))
    }

    @Test func dontAskAgainIsUnderEveryButtonAndLastInTabOrder() throws {
        let view = CmuxDialogView(spec: Self.spec)
        view.layoutSubtreeIfNeeded()
        let check = try #require(view.focusables.last as? NSButton)
        #expect(!(check is CmuxDialogButtonView), "the last control is not the check box")
        let checkFrame = check.convert(check.bounds, to: view)
        for (id, frame) in Self.frames(view) {
            #expect(checkFrame.maxY <= frame.minY + 0.5, "Don't ask again is not under \(id)")
        }
        let order = view.focusables.compactMap { ($0 as? CmuxDialogButtonView)?.button.id }
        #expect(order == ["cancel", "keep", "end-keep-layout", "end-everything"], "Tab order: \(order)")
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
