import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

extension MainPaneGutterSuites {
    /// https://github.com/manaflow-ai/cmux/issues/37425: with `appearance.chromeStyle` flat and
    /// `layout.panePadding` 0, split panes drew no line between them. A padding key counted as a
    /// bordered-pane setting even at 0, so the separation resolved to borders over the style's
    /// dividers: the divider's idle line went clear and only each pane's faint outline was left.
    @MainActor struct ChromeStylePaneSeparationTests {
        /// Runs `body` with `style` and `chrome` in the process-wide design settings, then restores them.
        func with<T>(_ style: ChromeStyle, _ chrome: PaneChromeOverrides, _ body: () throws -> T) rethrows -> T {
            let design = DesignSettings.shared
            let (beforeStyle, beforeChrome) = (design.chromeStyle, design.paneChrome)
            design.chromeStyle = style
            design.setPaneChrome(chrome)
            defer {
                design.chromeStyle = beforeStyle
                design.setPaneChrome(beforeChrome)
            }
            return try body()
        }

        @Test func flatWithZeroPaddingKeepsItsLineBetweenPanes() {
            with(.flat, PaneChromeOverrides(padding: 0)) {
                let style = LayoutStyle().applyingDesignMetrics()
                #expect(style.paneSeparation == .dividers)
                #expect(!style.showsPaneBorder, "no faint outline per pane in place of the line")
                #expect(style.showsDividerLine, "one line between neighboring panes")

                // The split handle the screen syncs from this style (ScreenContentView) draws its line at rest.
                let split = DividerHandleView(kind: .split(SplitID("split")), axis: .horizontal)
                split.showsIdleLine = style.showsDividerLine
                split.showsActiveLine = style.showsDividerFeedback
                #expect(split.isLineVisible)
            }
        }

        /// Zero padding is edge to edge, the look every style already has: it leaves each style's
        /// own separation in place (panes keeps its outlines, flat its line, bare nothing).
        @Test func zeroPaddingKeepsEveryStylesSeparation() {
            for chromeStyle in ChromeStyle.allCases {
                guard let expected = chromeStyle.paneSeparation else { continue }
                with(chromeStyle, PaneChromeOverrides(padding: 0)) {
                    #expect(Metrics.paneSeparation == expected, "\(chromeStyle)")
                }
            }
        }

        /// What still describes a bordered pane keeps borders: a padding above 0, a border color or width.
        @Test func aPaddedOrStyledPaneStillKeepsBorders() {
            let looks = [PaneChromeOverrides(padding: 4), PaneChromeOverrides(padding: 0, borderWidth: 2),
                         PaneChromeOverrides(borderColor: ThemeRGB(hex: 0x336699))]
            for look in looks {
                #expect(PaneSeparation.resolve(look, unset: .dividers) == .borders, "\(look)")
            }
            #expect(PaneSeparation.resolve(PaneChromeOverrides(padding: 0), unset: .dividers) == .dividers)
            #expect(PaneSeparation.resolve(PaneChromeOverrides(padding: 0, separation: PaneSeparation.none), unset: .dividers) == .none)
        }
    }
}
