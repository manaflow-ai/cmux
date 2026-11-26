import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileDesign
#if os(iOS)
import UIKit
#endif

/// Leo, 2026-11-23: "as for the composer, let's just unify it. like how the chatgpt one has it
/// combined", "too much space between the text and the buttons at the bottom", the send button
/// "has no reason to be white on whatever", block the Siri popup, and autocorrect on in the GUI.
@MainActor
@Suite struct ComposerUnifiedTests {
    static let line: CGFloat = 20.3
    static let plus = CGSize(width: 36, height: 36)
    static let send = CGSize(width: 76, height: 36)

    /// A draft of `characters` characters at about 8 pt each, wrapped at `width`.
    static func draft(_ characters: Int) -> (CGFloat) -> CGFloat {
        { width in ceil(CGFloat(characters) * 8 / max(1, width)) .clamped(min: 1) * line + 1 }
    }

    @Test func oneLineIsOneRowAsTallAsATouchTarget() {
        let g = ComposerRowGeometry.place(width: 353, leading: Self.plus, trailing: Self.send,
                                          fieldHeight: Self.draft(10), lineHeight: Self.line)
        #expect(g.inline)
        // 44 pt row: the card adds 2 pt above and below, 48 pt (was 96).
        #expect(g.size.height == 44)
        #expect(g.field.minX == Self.plus.width + ComposerRowGeometry.spacing)
        #expect(g.field.maxX == 353 - Self.send.width - ComposerRowGeometry.spacing)
        #expect(g.leading.midY == g.trailing.midY)
    }

    @Test func aWrappedDraftGoesAboveTheSameControls() {
        let inline = ComposerRowGeometry.place(width: 353, leading: Self.plus, trailing: Self.send,
                                               fieldHeight: Self.draft(10), lineHeight: Self.line)
        let wrapped = ComposerRowGeometry.place(width: 353, leading: Self.plus, trailing: Self.send,
                                                fieldHeight: Self.draft(150), lineHeight: Self.line)
        #expect(!wrapped.inline)
        #expect(wrapped.field.width == 353 - 2 * ComposerRowGeometry.textInset)
        // Text to the controls' row: 2 pt (was 14 pt of padding plus the controls' own 8).
        #expect(wrapped.leading.minY - wrapped.field.maxY <= 6)
        // Nothing moves sideways.
        #expect(wrapped.leading.minX == inline.leading.minX)
        #expect(wrapped.trailing.maxX == inline.trailing.maxX)
    }

    /// The choice reads the draft's height at the inline width only, so laying out the two-row
    /// result again gives the same answer (no flip-flop as the field widens).
    @Test func theChoiceIsStable() {
        for characters in stride(from: 0, through: 400, by: 7) {
            let a = ComposerRowGeometry.place(width: 353, leading: Self.plus, trailing: Self.send,
                                              fieldHeight: Self.draft(characters), lineHeight: Self.line)
            let b = ComposerRowGeometry.place(width: a.size.width, leading: Self.plus, trailing: Self.send,
                                              fieldHeight: Self.draft(characters), lineHeight: Self.line)
            #expect(a == b)
        }
    }

    @Test func aNarrowRowPutsTheDraftAbove() {
        let g = ComposerRowGeometry.place(width: 180, leading: Self.plus, trailing: Self.send,
                                          fieldHeight: Self.draft(1), lineHeight: Self.line)
        #expect(!g.inline)
    }

    #if os(iOS)
    private func theme(_ mac: CmuxMobileMacTheme? = nil) -> CmuxMobileAccentTheme {
        CmuxMobileAccentTheme(defaults: MacThemeTests.defaults(),
                              macTheme: mac ?? CmuxMobileMacTheme(defaults: MacThemeTests.defaults(), cache: MacThemeTests.cache()))
    }

    /// Default (monochrome) no longer paints Send white in dark and black in light.
    @Test func sendTakesAHueWithDefault() {
        let subject = theme()
        subject.accent = .neutral
        #expect(subject.sendToken != CmuxMobileAccent.neutral.accent)
        #expect(subject.sendToken == CmuxMobileAccent.blue.accent)
    }

    @Test func aChosenHueIsSendsHue() {
        let subject = theme()
        subject.accent = .magenta
        #expect(subject.sendToken == CmuxMobileAccent.magenta.accent)
        #expect(subject.onSendToken == CmuxMobileAccent.magenta.onAccent)
    }

    /// Following a Mac theme, Send is that terminal theme's blue (Mocha's bright blue).
    @Test func sendTakesTheMacThemesBlue() {
        let mac = CmuxMobileMacTheme(defaults: MacThemeTests.defaults(), cache: MacThemeTests.cache())
        mac.apply(MacThemeTests.mocha)
        let subject = theme(mac)
        #expect(subject.sendToken.dark == CmuxMobileRGBA(hex: "#89b4fa"))
        #expect(subject.onSendToken.dark == CmuxMobileRGBA(hex: "#000000"))
    }

    @Test func inkReads() {
        #expect(CmuxMobileAccentTheme.ink(on: CmuxMobileRGBA(hex: "#FFFFFF")) == CmuxMobileRGBA(hex: "#000000"))
        #expect(CmuxMobileAccentTheme.ink(on: CmuxMobileRGBA(hex: "#0064D1")) == CmuxMobileRGBA(hex: "#FFFFFF"))
        #expect(CmuxMobileAccentTheme.ink(on: CmuxMobileRGBA(hex: "#89b4fa")) == CmuxMobileRGBA(hex: "#000000"))
    }

    @Test func siriSuggestionsAreOffAndAutocorrectIsNotTouched() {
        let view = UITextView()
        view.autocorrectionType = .yes
        view.textContentType = .emailAddress
        ComposerTextTraits.blockSiriSuggestions(view)
        #expect(view.inlinePredictionType == .no)
        #expect(view.textContentType == nil)
        #expect(view.writingToolsBehavior == UIWritingToolsBehavior.none)
        #expect(view.autocorrectionType == .yes)
    }
    #endif
}

private extension CGFloat {
    func clamped(min lower: CGFloat) -> CGFloat { Swift.max(lower, self) }
}
