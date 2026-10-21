import CoreGraphics
import Testing
@testable import CmuxHomeRender

/// The Chief chat's two looks (`home.chiefBubbleStyle`): the default iMessage
/// style gives the Chief Messages' grey; the theme style takes the theme's
/// colours and nothing in it is Messages' blue.
@MainActor
@Suite struct BubbleStyleTests {
    /// Rose Pine: a tinted dark theme, the case Messages' blue looked out of place on.
    static let rosePine = HomePalette.Theme(background: .rgb255(25, 23, 36), foreground: .rgb255(224, 222, 244),
                                            accent: .rgb255(196, 167, 231), failure: .rgb255(235, 111, 146))
    static let messagesBlue = HomeColor.rgb255(2, 132, 254)
    static let iris = HomeColor.rgb255(196, 167, 231), onIris = HomeColor.rgb255(25, 23, 36)

    /// A rough sRGB stand-in for check-system-blue.py's blue test: blue well above red and green.
    static func isBlue(_ c: HomeColor) -> Bool { c.blue - max(c.red, c.green) > 0.25 }

    @Test func themeStyleSentBubblesAreTheThemeAccent() {
        let p = HomePalette.themeStyled(Self.rosePine, sent: (Self.iris, Self.onIris))
        #expect(p.outgoingGradient.allSatisfy { $0.color == Self.iris }, "one flat accent fill, no viewport shading")
        #expect(p.outgoingText == Self.onIris)
        #expect(p.caret == Self.iris)
        // The Chief's bubbles are the theme's surface, as `themed` mixes it.
        #expect(p.incomingBubble == HomePalette.themed(Self.rosePine).incomingBubble)
    }

    @Test func withNoAccentTheSentBubbleIsANeutralStepOfTheTheme() {
        let p = HomePalette.themeStyled(Self.rosePine)
        let fill = Self.rosePine.background.mixed(with: Self.rosePine.foreground, 0.22)
        #expect(p.outgoingGradient.allSatisfy { $0.color == fill })
        #expect(p.outgoingText == Self.rosePine.foreground)
        #expect(p.caret == Self.rosePine.foreground, "the caret stays the theme's text, never a grey")
        #expect(fill != p.incomingBubble, "the person's and the Chief's bubbles differ")
    }

    @Test func themeStyleHasNoMessagesBlueOnLightOrDark() {
        let light = HomePalette.Theme(background: .rgb255(250, 244, 237), foreground: .rgb255(87, 82, 121),
                                      accent: .rgb255(144, 122, 169), failure: .rgb255(180, 99, 122))
        for theme in [Self.rosePine, light] {
            for active in [true, false] {
                for p in [HomePalette.themeStyled(theme, active: active), HomePalette.themeStyled(theme, sent: (theme.accent, theme.background), active: active)] {
                    let colors = p.outgoingGradient.map(\.color) + [p.incomingBubble, p.caret, p.outgoingText, p.incomingText]
                    #expect(!colors.contains(Self.messagesBlue))
                    #expect(!colors.contains(where: Self.isBlue), "no blue on a theme that names none")
                }
            }
        }
    }

    @Test func iMessageStyleGivesTheChiefMessagesGrey() {
        let dark = HomePalette.iMessageStyled(Self.rosePine)
        #expect(dark.incomingBubble == .rgb255(59, 59, 61))
        #expect(dark.incomingText == .gray255(225))
        let light = HomePalette.iMessageStyled(HomePalette.Theme(background: .gray255(255), foreground: .gray255(20),
                                                                 accent: Self.messagesBlue, failure: .rgb255(255, 59, 48)))
        #expect(light.incomingBubble == .rgb255(233, 233, 235))
        #expect(light.incomingText == .gray255(36))
        // Its sent bubbles are the accent the host passes (Messages' blue), shaded like Messages'.
        var blue = Self.rosePine
        blue.accent = Self.messagesBlue
        let p = HomePalette.iMessageStyled(blue)
        #expect(p.outgoingGradient.first?.color == Self.messagesBlue)
        #expect(p.outgoingText == .gray255(255))
    }
}
