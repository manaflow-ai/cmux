import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Testing

/// cg-design-judge's sidebar Thunderdome (2026-10-14, cx-7yywz): the solid pastel group bands are the
/// loudest thing in the sidebar and look the same in Latte and Apple Light. Leo: group colors come
/// from the theme. Debug Settings offers quieter headers (`sidebar.groupHeader`: the name and the
/// group's color line, the name tinted, or a faint wash) and the theme's colors
/// (`sidebar.groupColors`); the band and the fixed palette stay the default
/// (`GroupPaletteDefaultTests`).
@MainActor @Suite(.serialized) struct GroupHeaderThemeLookTests {
    typealias Fixture = GroupPaletteDefaultTests

    /// Catppuccin Latte's terminal palette.
    static func latte() throws -> ThemeScope {
        try Fixture.room("Catppuccin Latte", background: 0xEFF1F5, foreground: 0x4C4F69,
                         palette: [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE])
    }

    /// Apple System Colors (light)'s terminal palette.
    static func appleLight() throws -> ThemeScope {
        try Fixture.room("Apple System Colors", background: 0xFFFFFF, foreground: 0x000000,
                         palette: [0x1A1A1A, 0xCC372E, 0x26A439, 0xCDAC08, 0x0869CB, 0x9647BF, 0x479EC2, 0x98989D])
    }

    /// Runs `body` with the two Debug Settings choices set, then clears them. The store is active
    /// without a file, so nothing is written.
    static func withLook(_ style: SidebarGroupHeaderStyle, _ palette: SidebarGroupPalette, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let keys = [SidebarGroupHeaderStyle.tunable.key, SidebarGroupPalette.tunable.key]
        defer { keys.forEach { TunableStore.shared.set($0, nil) } }
        try #require(TunableStore.shared.set(keys[0], style.tunableValue) == style.tunableValue, "the header look takes the override")
        try #require(TunableStore.shared.set(keys[1], palette.tunableValue) == palette.tunableValue, "the palette takes the override")
        try body()
    }

    /// The sidebar with one group per color of `Fixture.order`, drawn in `scope`.
    static func headers(in scope: ThemeScope) throws -> (SidebarView, [(GroupHeaderRowView, GroupColor)]) {
        let (sidebar, ids) = try Fixture.sidebar(Fixture.order)
        scope.root(sidebar)
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let headers = try zip(ids, Fixture.order).map { id, color in
            let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
            header.layoutSubtreeIfNeeded()
            header.updateLayer()
            return (header, color)
        }
        return (sidebar, headers)
    }

    static func ink(_ color: NSColor?) throws -> ThemeRGB { try Fixture.rgb(color?.cgColor) }

    @Test func theThemesColorsDrawTheGroupsAndDifferBetweenLatteAndAppleLight() throws {
        try Self.withLook(.line, .theme) {
            var drawnRed: [ThemeRGB] = []
            for (name, scope) in [("Latte", try Self.latte()), ("Apple Light", try Self.appleLight())] {
                let (sidebar, headers) = try Self.headers(in: scope)
                for (header, color) in headers {
                    let want = try #require(color.themeRGB(scope.tokens))
                    let dot = try Fixture.rgb(header.dot.backgroundColor)
                    #expect(Fixture.same(dot, want), "\(name) \(color) dot: \(dot), want the theme's \(want)")
                    if color == .red { drawnRed.append(dot) }
                }
                let lines = Fixture.views(GroupLineView.self, in: sidebar)
                #expect(!lines.isEmpty, "\(name): no members' line")
                for line in lines {
                    line.updateLayer()
                    let drawn = try Fixture.rgb(line.railShape.fillColor)
                    let want = try #require(line.color.token.themeRGB(scope.tokens))
                    #expect(Fixture.same(drawn, want), "\(name) \(line.color.token) line: \(drawn), want the theme's \(want)")
                }
            }
            #expect(drawnRed.count == 2 && !Fixture.same(drawnRed[0], drawnRed[1]), "red reads the same in Latte and Apple Light")
        }
    }

    @Test(arguments: [SidebarGroupHeaderStyle.line, .tinted])
    func aQuietHeaderDrawsNoBandOnlyTheNameAndTheColorLine(_ style: SidebarGroupHeaderStyle) throws {
        try Self.withLook(style, .theme) {
            let scope = try Self.latte()
            let (_, headers) = try Self.headers(in: scope)
            for (header, color) in headers {
                let alpha = header.pill.isHidden ? 0 : (header.pill.backgroundColor?.alpha ?? 0)
                #expect(alpha == 0, "\(style) \(color): the header still draws a band")
                #expect(!header.dot.isHidden, "\(style) \(color): no color dot where the line starts")
                let group = try #require(color.themeRGB(scope.tokens))
                let name = try Self.ink(header.name.textColor)
                // A tinted name keeps text contrast: the group's color, darkened as far as 4.5:1 needs.
                let tinted = ThemeTokens.readable(group, over: scope.tokens.sidebarBackground, minimum: ThemeTokens.minimumTextContrast)
                let want = style == .tinted ? tinted : scope.tokens.textPrimary
                #expect(Fixture.same(name, want), "\(style) \(color) name: \(name), want \(want)")
            }
        }
    }

    @Test func theWashIsAFaintTintBehindAPrimaryName() throws {
        try Self.withLook(.wash, .theme) {
            let scope = try Self.appleLight()
            let (_, headers) = try Self.headers(in: scope)
            let background = scope.tokens.sidebarBackground.withAlpha(1)
            for (header, color) in headers {
                #expect(!header.pill.isHidden && !header.dot.isHidden, "\(color): no wash or no color dot")
                let fill = try Fixture.rgb(header.pill.backgroundColor)
                #expect(!Fixture.same(fill, background), "\(color): the wash is not tinted")
                #expect(fill.contrast(with: background) < 1.25, "\(color): the wash is \(fill.contrast(with: background)):1 against the sidebar, not faint")
                #expect(Fixture.same(try Self.ink(header.name.textColor), scope.tokens.textPrimary), "\(color): the name is not primary ink")
            }
        }
    }
}
