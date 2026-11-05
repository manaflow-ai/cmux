import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// Lawrence 2026-11-05: "invariant: groups must always have a visible bg color, groups should support both glassy and
/// solid bgs too". In every bundled theme (Ghostty's and cmux's own, each in the mode its colors give it), with an
/// opaque sidebar and a see-through one, for every group color (none, each palette color, a custom color, and a custom
/// color equal to the sidebar's own background), as the header bar and as the quiet looks' wash, glass and solid,
/// from the fixed palette and from the theme, at rest and hovered: the background as seen over the sidebar keeps
/// ``GroupBackground/minimumVisibleContrast`` against it. Glass composites to the same color and is never opaque; the
/// bar's ink keeps 4.5:1. Before, a group with no color drew no background at all (1:1, an invisible group).
@MainActor @Suite struct GroupBackgroundEveryThemeTests {
    static let opacities = [1.0, 0.7]

    static func tints(_ tokens: ThemeTokens) -> [(String, GroupTint)] {
        [("none", GroupTint.none)] + GroupColor.allCases.map { ($0.rawValue, GroupTint.palette($0)) } + [
            ("custom red", .custom(ThemeRGB(hex: 0xD0312D))),
            ("custom sidebar", .custom(tokens.sidebarBackground.withAlpha(1))),
        ]
    }

    static func tokens(_ theme: CardNeverOpaqueTests.BundledTheme, opacity: Double) -> ThemeTokens {
        var input = theme.input
        input.backgroundOpacity = opacity
        return ThemeTokens.derive(from: input)
    }

    @Test func everyGroupBackgroundIsVisibleInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        let minimum = GroupBackground.minimumVisibleContrast - 0.005
        var failures: [String] = []
        var checked = 0
        for theme in themes {
            for opacity in Self.opacities {
                let tokens = Self.tokens(theme, opacity: opacity)
                let ground = tokens.sidebarBackground.withAlpha(1)
                for (name, tint) in Self.tints(tokens) {
                    for strength in [GroupBackground.Strength.band, .wash] {
                        for glass in [false, true] {
                            for themed in [false, true] {
                                checked += 1
                                let label = "\(theme.label) opacity \(opacity) \(name) \(strength) \(glass ? "glass" : "solid")\(themed ? " themed" : "")"
                                let background = GroupBackground(tint: tint, strength: strength, glass: glass, themed: themed, tokens: tokens)
                                let rest = background.fill.composited(over: ground)
                                if rest.contrast(with: ground) < minimum {
                                    failures.append(String(format: "%@: rest %.3f:1", label, rest.contrast(with: ground)))
                                }
                                let hovered = background.painted(over: [tokens.hoverFill]).composited(over: ground)
                                if hovered.contrast(with: ground) < minimum {
                                    failures.append(String(format: "%@: hovered %.3f:1", label, hovered.contrast(with: ground)))
                                }
                                if glass {
                                    if background.fill.alpha >= 1 { failures.append("\(label): glass is opaque") }
                                    if background.rim == nil { failures.append("\(label): glass has no rim") }
                                    if !CardNeverOpaqueTests.closeEnough(rest, background.shown) {
                                        failures.append("\(label): glass shows \(rest), want \(background.shown)")
                                    }
                                } else if background.fill.alpha < 1 {
                                    failures.append("\(label): solid is translucent")
                                }
                                if strength == .band, background.ink.contrast(with: background.shown) < ThemeTokens.minimumTextContrast - 0.01 {
                                    failures.append(String(format: "%@: ink %.2f:1 on the bar", label, background.ink.contrast(with: background.shown)))
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(checked > 100_000)
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures; first:\n" + failures.prefix(80).joined(separator: "\n")))
    }

    /// `auto` is glass exactly where the sidebar is see-through; `glass` and `solid` hold everywhere.
    @Test func automaticIsGlassOnlyOverASeeThroughSidebar() {
        #expect(SidebarGroupBackgroundStyle.auto.drawsGlass(seeThrough: true))
        #expect(!SidebarGroupBackgroundStyle.auto.drawsGlass(seeThrough: false))
        #expect(SidebarGroupBackgroundStyle.glass.drawsGlass(seeThrough: false))
        #expect(!SidebarGroupBackgroundStyle.solid.drawsGlass(seeThrough: true))
    }
}

extension CardNeverOpaqueTests {
    /// Two colors that differ by less than one 8-bit step in each channel.
    static func closeEnough(_ a: ThemeRGB, _ b: ThemeRGB) -> Bool {
        abs(a.red - b.red) < 0.004 && abs(a.green - b.green) < 0.004 && abs(a.blue - b.blue) < 0.004
    }
}
