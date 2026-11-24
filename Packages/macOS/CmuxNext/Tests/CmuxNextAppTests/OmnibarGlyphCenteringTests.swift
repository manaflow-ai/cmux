import AppKit
@testable import CmuxNextBrowser
import CmuxNextBrowserCore
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// Lucas 2026-11-18: "the containers/hover is not centered within the icon for majority if not all. we need consistency
/// in that, use flex or something else that is realiable." Each toolbar button's, the star's and the pane ⋮'s glyph ink
/// sits in the middle of its hover box at 2x: as many clear pixels above it as below, left as right. Where the counts
/// cannot match (an odd and an even pixel count) the ink sits half a pixel up and left, at every box alike.
@MainActor @Suite(.serialized, .closesItsWindows) struct OmnibarGlyphCenteringTests {
    /// The clear pixels around `view`'s ink at 2x: top, bottom, left, right.
    static func margins(_ view: NSView) throws -> (top: Int, bottom: Int, left: Int, right: Int) {
        let pixels = try OmnibarTrailingGlyphsTests.alpha(view)
        let rows = pixels.map { $0.max() ?? 0 }
        let columns = (0..<(pixels.first?.count ?? 0)).map { x in pixels.map { $0[x] }.max() ?? 0 }
        let litRows = rows.indices.filter { rows[$0] > 0.02 }, litColumns = columns.indices.filter { columns[$0] > 0.02 }
        let top = try #require(litRows.first), bottom = rows.count - 1 - (try #require(litRows.last))
        let left = try #require(litColumns.first), right = columns.count - 1 - (try #require(litColumns.last))
        return (top, bottom, left, right)
    }

    @Test(arguments: DensityPreset.allCases)
    func everyGlyphSitsInTheMiddleOfItsBox(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        design.densityTokens = preset.tokens
        _ = NSApplication.shared
        let window = TwoXWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: 0, width: 1200, height: 500)
        window.contentView = chrome
        let bar = chrome.addressBar
        bar.starButton.isHidden = false
        bar.starButton.state = .off
        let puzzle = chrome.extensionToolbar.puzzle
        if puzzle.superview == nil { chrome.addSubview(puzzle) }
        let pane = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 600, height: Metrics.tabStripHeight))
        pane.show(more: true, lit: false)
        window.contentView?.addSubview(pane)
        chrome.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        let boxes: [(String, NSView)] = [("back", chrome.backButton), ("forward", chrome.forwardButton), ("reload", chrome.reloadButton),
                                         ("puzzle", puzzle), ("more", try #require(chrome.toolbarButtons.anchor(for: .overflow))),
                                         ("star", bar.starButton), ("tab bar more", pane.moreButton)]
        for (name, box) in boxes {
            let m = try Self.margins(box)
            #expect(m.top == (m.top + m.bottom) / 2 && m.left == (m.left + m.right) / 2,
                    "\(preset) \(name): \(m.top) clear pixels above the ink, \(m.bottom) below, \(m.left) left, \(m.right) right")
        }
    }
}
