import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextDesign
import Testing

/// The Keycap Playground (Lawrence 2026-11-16: "come up with more variations, think about how linear would do it")
/// draws every keycap style on real dialog buttons, and each style keeps its key inside its button, centred on it,
/// clear of the title, and on the buttons it names.
@MainActor @Suite(.serialized) struct KeycapPlaygroundTests {
    private static func keycap(in button: CmuxDialogButtonView) -> NSView? {
        button.subviews.first { $0 is CmuxDialogKeycapView }
    }

    @Test(arguments: [false, true])
    func everyStyleShowsInEitherTheme(isDark: Bool) {
        let view = CmuxKeycapPlaygroundView(themes: CmuxToastPlaygroundThemes(colors: [:]), isDark: isDark)
        #expect(view.sheets.map(\.style) == CmuxDialogKeycapStyle.allCases)
        #expect(view.sheets.allSatisfy { $0.isDark == isDark })
    }

    @Test(arguments: CmuxDialogKeycapStyle.allCases)
    func theKeySitsInsideItsButtonClearOfTheTitle(style: CmuxDialogKeycapStyle) throws {
        let sheet = CmuxKeycapPlaygroundSheet(style: style, isDark: false, themes: CmuxToastPlaygroundThemes(colors: [:]))
        #expect(sheet.buttons.count == CmuxDialogButtonLook.State.allCases.count)
        for (cancel, confirm) in sheet.buttons {
            for button in [cancel, confirm] {
                button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
                button.layoutSubtreeIfNeeded()
                let found = Self.keycap(in: button)
                #expect((found != nil) == style.showsKey(for: button.button.role), "\(style) \(button.button.id)")
                guard let key = found else { continue }
                #expect(button.bounds.contains(key.frame), "\(style): the key \(key.frame) leaves \(button.bounds)")
                #expect(abs(key.frame.midY - button.bounds.midY) <= 0.5, "\(style): the key is off centre")
                let title = button.attributedTitle.size().width
                // The title starts at the leading inset (it carries the key's room as kern at its end).
                let titleEnd = CmuxDialogMetrics.keycapLeading + title - (key.frame.width + style.gap + style.trailing - CmuxDialogMetrics.keycapLeading)
                #expect(key.frame.minX >= titleEnd - 0.5, "\(style): the key \(key.frame) overlaps the title ending at \(titleEnd)")
                #expect(button.bounds.height == CmuxDialogMetrics.buttonHeight)
            }
        }
    }

    @Test func aPlatedKeyIsConcentricWithItsButton() throws {
        for style in CmuxDialogKeycapStyle.allCases where style.hasPlate {
            let sheet = CmuxKeycapPlaygroundSheet(style: style, isDark: true, themes: CmuxToastPlaygroundThemes(colors: [:]))
            let button = try #require(sheet.buttons.first?.confirm)
            button.frame = NSRect(origin: .zero, size: button.intrinsicContentSize)
            button.layoutSubtreeIfNeeded()
            let key = try #require(Self.keycap(in: button))
            let radius = try #require(key.layer).cornerRadius
            let inset = button.bounds.maxX - key.frame.maxX
            let expected = max(CmuxDialogMetrics.buttonCornerRadius - inset, CmuxDialogMetrics.keycapCornerFloor)
            #expect(abs(radius - min(expected, key.frame.height / 2)) <= 0.5, "\(style): r\(radius), inset \(inset)")
        }
    }
}
