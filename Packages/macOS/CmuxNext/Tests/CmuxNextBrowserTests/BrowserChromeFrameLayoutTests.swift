import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import Testing
import CmuxNextWakeups

/// The browser toolbar and omnibar lay out with frames from
/// pure functions (`BrowserChromeLayout`, `ToolbarRowLayout`, `AddressBarLayout`),
/// not Auto Layout. The pure layouts are checked at narrow, normal and wide
/// widths, right to left, with the toolbar at the bottom and with an accessory
/// bar; the views are checked to place their subviews at those frames with no
/// constraints of their own.
@MainActor @Suite(.serialized) struct BrowserChromeFrameLayoutTests {
    static let metrics = ToolbarRowLayout.Metrics(inset: 8, barMargin: 6, buttonSpacing: 3, buttonSize: 28, barTop: 0, barHeight: 28)

    static func row(width: CGFloat, height: CGFloat = 38, position: ToolbarPosition = .top, navigation: Int = 3,
                    trailing: ToolbarRowLayout.Trailing? = .init(slotWidth: 28, buttonsWidth: 59)) -> ToolbarRowLayout {
        ToolbarRowLayout(.init(size: CGSize(width: width, height: height), position: position, navigationButtons: navigation,
                               trailing: trailing, metrics: metrics))
    }

    // MARK: Toolbar row

    @Test func aNormalRowPlacesNavigationOmnibarSlotAndButtons() {
        let row = Self.row(width: 900)
        let m = Self.metrics
        #expect(row.navigation.count == 3)
        #expect(row.navigation[0].minX == m.inset)
        #expect(row.navigation[1].minX == row.navigation[0].maxX + m.buttonSpacing)
        #expect(row.address.minX == row.navigation[2].maxX + m.barMargin)
        #expect(row.buttons.maxX == 900 - m.inset)
        #expect(row.slot.maxX + m.buttonSpacing == row.buttons.minX)
        #expect(row.address.maxX + m.barMargin == row.slot.minX)
        #expect(row.address.height == m.barHeight)
        for rect in row.navigation + [row.slot, row.buttons] {
            #expect(rect.midY == row.address.midY, "every control sits on the omnibar's center line")
            #expect(rect.height == m.buttonSize)
        }
    }

    @Test func aNarrowRowNeverGivesTheOmnibarANegativeWidth() {
        let row = Self.row(width: 120)
        #expect(row.address.width == 0)
        #expect(row.buttons.maxX == 120 - Self.metrics.inset, "the trailing buttons keep the trailing edge")
    }

    @Test func aWideRowGivesTheOmnibarTheRest() {
        let normal = Self.row(width: 900), wide = Self.row(width: 2400)
        #expect(wide.address.minX == normal.address.minX)
        #expect(wide.address.width == normal.address.width + 1500)
    }

    @Test func forwardHiddenMovesTheOmnibarToReload() {
        let row = Self.row(width: 900, navigation: 2)
        #expect(row.navigation.count == 2)
        #expect(row.address.minX == row.navigation[1].maxX + Self.metrics.barMargin)
    }

    @Test func anOmnibarOnlyRowSpansBetweenTheInsets() {
        let row = Self.row(width: 600, navigation: 0, trailing: nil)
        #expect(row.navigation.isEmpty)
        #expect(row.address.minX == Self.metrics.inset)
        #expect(row.address.maxX == 600 - Self.metrics.inset)
        #expect(row.slot == .zero && row.buttons == .zero)
    }

    @Test func atTheBottomTheOmnibarKeepsItsGapFromTheBottomEdge() {
        var metrics = Self.metrics
        metrics.barTop = 4
        let row = ToolbarRowLayout(.init(size: CGSize(width: 900, height: 40), position: .bottom, navigationButtons: 3,
                                         trailing: nil, metrics: metrics))
        #expect(row.address.maxY == 40 - 4, "top-down: the bar ends its gap above the bottom edge")
        let top = ToolbarRowLayout(.init(size: CGSize(width: 900, height: 40), position: .top, navigationButtons: 3,
                                         trailing: nil, metrics: metrics))
        #expect(top.address.minY == 4)
    }

    @Test func rightToLeftMirrorsTheRow() {
        let row = Self.row(width: 900)
        let rtl = ChromeFrameMapping(size: CGSize(width: 900, height: 38), isFlipped: true, rightToLeft: true)
        #expect(rtl.map(row.navigation[0]).maxX == 900 - Self.metrics.inset, "Back sits at the right edge")
        #expect(rtl.map(row.buttons).minX == Self.metrics.inset, "the toolbar buttons sit at the left edge")
        let ltr = ChromeFrameMapping(size: CGSize(width: 900, height: 38), isFlipped: true, rightToLeft: false)
        #expect(ltr.map(row.address) == row.address)
    }

    @Test func aNonFlippedViewGetsTheRowsYUp() {
        let mapping = ChromeFrameMapping(size: CGSize(width: 100, height: 50), isFlipped: false, rightToLeft: false)
        #expect(mapping.map(CGRect(x: 0, y: 0, width: 100, height: 10)) == CGRect(x: 0, y: 40, width: 100, height: 10))
    }

    // MARK: Chrome rows

    @Test func theRowsStackFromTheTopWithAnAccessoryBarAndABand() {
        let rows = BrowserChromeLayout(.init(size: CGSize(width: 900, height: 600), position: .top, toolbarHeight: 40,
                                             accessoryHeight: 26, bandHeight: 30, progressThickness: 2))
        #expect(rows.toolbar == CGRect(x: 0, y: 0, width: 900, height: 40))
        #expect(rows.accessoryBar == CGRect(x: 0, y: 40, width: 900, height: 26))
        #expect(rows.band == CGRect(x: 0, y: 66, width: 900, height: 30))
        #expect(rows.content == CGRect(x: 0, y: 96, width: 900, height: 504))
        #expect(rows.progressLine.maxY == rows.toolbar.maxY, "the progress line runs along the toolbar's page edge")
    }

    @Test func atTheBottomTheRowsAreMirrored() {
        let rows = BrowserChromeLayout(.init(size: CGSize(width: 900, height: 600), position: .bottom, toolbarHeight: 40,
                                             accessoryHeight: 26, bandHeight: 30, progressThickness: 2))
        #expect(rows.toolbar.maxY == 600)
        #expect(rows.accessoryBar.maxY == rows.toolbar.minY)
        #expect(rows.band.maxY == rows.accessoryBar.minY)
        #expect(rows.content == CGRect(x: 0, y: 0, width: 900, height: 504))
        #expect(rows.progressLine.minY == rows.toolbar.minY)
        #expect(600 - rows.band.maxY == 66, "the toolbar and the accessory bar from the bottom edge")
    }

    @Test func aHiddenToolbarGivesThePageItsRoom() {
        let rows = BrowserChromeLayout(.init(size: CGSize(width: 900, height: 600), position: .top, toolbarHeight: 0,
                                             accessoryHeight: 0, bandHeight: 0, progressThickness: 2))
        #expect(rows.toolbar.height == 0)
        #expect(rows.content == CGRect(x: 0, y: 0, width: 900, height: 600))
    }

    // MARK: Omnibar inside

    static func bar(width: CGFloat, badges: CGSize) -> AddressBarLayout {
        AddressBarLayout(.init(size: CGSize(width: width, height: 28), chipSize: CGSize(width: 24, height: 24), fieldHeight: 18,
                               badgesSize: badges, chipLeading: 2, textLeading: 5, trailingPadding: 8, badgesTrailing: 4,
                               cardTopOutset: 0, cardSideOutset: 0))
    }

    @Test func theFieldRunsFromTheChipToTheEndWithoutBadges() {
        let bar = Self.bar(width: 400, badges: .zero)
        #expect(bar.chip == CGRect(x: 2, y: 2, width: 24, height: 24))
        #expect(bar.field.minX == bar.chip.maxX + 5)
        #expect(bar.field.maxX == 400 - 8)
        #expect(bar.field.midY == 14)
        #expect(bar.badges == .zero)
        #expect(bar.pill == CGRect(x: 0, y: 0, width: 400, height: 28))
    }

    @Test func theFieldEndsBeforeTheBadges() {
        let bar = Self.bar(width: 400, badges: CGSize(width: 60, height: 18))
        #expect(bar.badges.maxX == 400 - 4)
        #expect(bar.badges.midY == 14)
        #expect(bar.field.maxX == bar.badges.minX - 5)
    }

    @Test func aNarrowOmnibarNeverGivesTheFieldANegativeWidth() {
        #expect(Self.bar(width: 20, badges: CGSize(width: 60, height: 18)).field.width == 0)
    }

    @Test func theButtonLineIsEqualButtonsAndGaps() {
        let line = ButtonLineLayout(count: 3, button: 28, spacing: 3, height: 28)
        #expect(line.width == 90)
        #expect(line.frames.map(\.minX) == [0, 31, 62])
        #expect(ButtonLineLayout(count: 0, button: 28, spacing: 3, height: 28).width == 0)
    }

    // MARK: The views

    /// Constraints installed on `view` other than AppKit's own for framed subviews
    /// (`NSAutoresizingMaskLayoutConstraint`, made when a stack inside needs its frame).
    static func ownConstraints(_ view: NSView) -> [NSLayoutConstraint] {
        view.constraints.filter { !String(describing: type(of: $0)).hasPrefix("NSAutoresizingMask") }
    }

    static func chrome(width: CGFloat = 900) -> BrowserChromeView {
        let engine = MockBrowserEngine(kind: .cef, completesNavigationsImmediately: true)
        let page = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let chrome = BrowserChromeView(tab: page, mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: nil)
        chrome.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        chrome.layoutSubtreeIfNeeded()
        return chrome
    }

    @Test func theToolbarAndOmnibarUseNoConstraintsOfTheirOwn() {
        let chrome = Self.chrome()
        let framed: [NSView] = [chrome.toolbar, chrome.separator, chrome.accessoryBar, chrome.contentContainer, chrome.backButton,
                                chrome.forwardButton, chrome.reloadButton, chrome.addressBar, chrome.extensionSlot,
                                chrome.toolbarButtons, chrome.tab.contentView] + chrome.addressBar.subviews + chrome.toolbarButtons.subviews
        for view in framed {
            #expect(view.translatesAutoresizingMaskIntoConstraints, "\(type(of: view)) is placed by constraints")
        }
        #expect(Self.ownConstraints(chrome.toolbar).isEmpty)
        #expect(Self.ownConstraints(chrome.addressBar).isEmpty)
        #expect(Self.ownConstraints(chrome.toolbarButtons).isEmpty)
    }

    /// Every chrome button under `view`, hidden ones included.
    static func chromeButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub -> [NSButton] in
            let own = ([sub as? ChromeIconButton, sub as? ChromeTextButton] as [NSButton?]).compactMap { $0 }
            return own + chromeButtons(in: sub)
        }
    }

    /// A framed button keeps its frame through its required autoresizing-mask
    /// constraints. In a window that uses Auto Layout, a required intrinsic size
    /// would conflict with them (a hidden toolbar button keeps a zero frame).
    @Test func framedButtonsHaveNoRequiredSizeInAnAutoLayoutWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let chrome = Self.chrome()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = host
        chrome.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: host.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        window.layoutIfNeeded()
        let hidden = try #require(chrome.toolbarButtons.subviews.first { $0.isHidden } as? ChromeIconButton,
                                  "the default pins hide some toolbar buttons")
        #expect(hidden.frame.size == .zero, "the line never framed it")
        let buttons = Self.chromeButtons(in: chrome)
        #expect(buttons.contains(chrome.backButton) && buttons.contains(hidden))
        for button in buttons {
            for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                #expect(button.contentHuggingPriority(for: orientation) < .required, "\(type(of: button)) hugs at required")
                #expect(button.contentCompressionResistancePriority(for: orientation) < .required,
                        "\(type(of: button)) resists compression at required")
                let required = button.constraintsAffectingLayout(for: orientation).filter {
                    $0.priority == .required && String(describing: type(of: $0)).hasPrefix("NSContentSize")
                }
                #expect(required.isEmpty, "\(type(of: button)) has a required intrinsic size: \(required)")
            }
        }
    }

    @Test func theViewsSitAtThePureLayoutsFrames() throws {
        for width in [CGFloat(480), 900, 1800] {
            let chrome = Self.chrome(width: width)
            let rows = chrome.chromeLayout, mapping = chrome.chromeFrameMapping
            #expect(chrome.toolbar.frame == mapping.map(rows.toolbar))
            #expect(chrome.contentContainer.frame == mapping.map(rows.content))
            #expect(chrome.tab.contentView.frame == chrome.contentContainer.bounds, "the page fills the page area")
            let row = try #require(chrome.toolbar.rowLayout)
            let rowMapping = chrome.toolbar.chromeFrameMapping
            #expect(chrome.backButton.alignmentRect(forFrame: chrome.backButton.frame) == rowMapping.map(row.navigation[0]))
            #expect(chrome.addressBar.frame == rowMapping.map(row.address))
            #expect(chrome.toolbarButtons.frame == rowMapping.map(row.buttons))
        }
    }

    @Test func rightToLeftPutsBackAtTheRightEdge() throws {
        let chrome = Self.chrome()
        chrome.toolbar.userInterfaceLayoutDirection = .rightToLeft
        chrome.toolbar.needsLayout = true
        chrome.layoutSubtreeIfNeeded()
        let inset = try #require(chrome.toolbar.metrics).inset
        let back = chrome.backButton.alignmentRect(forFrame: chrome.backButton.frame)
        #expect(back.maxX == chrome.toolbar.bounds.width - inset)
        #expect(chrome.toolbarButtons.frame.minX == inset)
        #expect(chrome.addressBar.frame.maxX < back.minX)
    }

    @Test func anAccessoryBarSitsBetweenTheToolbarAndThePage() {
        let chrome = Self.chrome()
        let bar = NSView()
        chrome.setAccessoryView(bar, height: 26)
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.accessoryBar.frame.height == 26)
        #expect(chrome.accessoryBar.frame.maxY == chrome.toolbar.frame.minY, "y up: right under the toolbar")
        #expect(chrome.contentContainer.frame.maxY == chrome.accessoryBar.frame.minY)
        #expect(bar.frame == chrome.accessoryBar.bounds, "the host's bar fills the accessory row")
        chrome.setAccessoryView(nil, height: 26)
        chrome.layoutSubtreeIfNeeded()
        #expect(chrome.accessoryBar.frame.height == 0)
        #expect(chrome.contentContainer.frame.maxY == chrome.toolbar.frame.minY)
    }

    @Test func theTabStripBandFollowsTheAccessoryBar() {
        let chrome = Self.chrome()
        chrome.setAccessoryView(NSView(), height: 26)
        chrome.setPaneHeaderBandHeight(30)
        let band = chrome.paneHeaderBandRect
        chrome.layoutSubtreeIfNeeded()
        #expect(band.height == 30)
        #expect(band.maxY == chrome.accessoryBar.frame.minY, "the band starts under the accessory bar")
        #expect(chrome.contentContainer.frame.maxY == band.minY, "the page starts under the band")
    }

    /// The layout pass that hides the toolbar (Toggle Omnibar, a fullscreen page) reports the band's
    /// final row, the same pass the rows take theirs from, so a pane's strip framed from the report
    /// lands next to the page in that pass, inside the hide animation too.
    @Test func hidingTheToolbarReportsTheBandsFinalRowInTheSamePass() throws {
        let chrome = Self.chrome()
        chrome.setPaneHeaderBandHeight(30)
        chrome.layoutSubtreeIfNeeded()
        var reported: [CGRect] = []
        chrome.onPaneHeaderBandLayout = { reported.append($0) }
        chrome.toggleOmnibar()
        let hidden = try #require(reported.last, "the hide's layout pass reports the band")
        #expect(hidden.maxY == chrome.bounds.maxY, "y up: the band is the top row with the toolbar hidden")
        #expect(hidden.minY == chrome.contentContainer.frame.maxY, "the page starts under the band")
        #expect(hidden == chrome.paneHeaderBandRect)
        reported.removeAll()
        chrome.toggleOmnibar()
        let shown = try #require(reported.last, "the show's layout pass reports the band")
        #expect(shown.maxY == chrome.toolbar.frame.minY, "back under the toolbar")
        #expect(shown.minY == chrome.contentContainer.frame.maxY)
    }

    @Test func theOmnibarOnlyRowFramesItsBarAndButtons() throws {
        let row = OmnibarToolbarView(suggestionEngine: OmniboxSuggestionEngine(), navigation: true,
                                     mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        row.frame = NSRect(x: 0, y: 0, width: 700, height: row.preferredHeight)
        row.layoutSubtreeIfNeeded()
        let layout = try #require(row.rowLayout)
        let mapping = row.chromeFrameMapping
        #expect(row.addressBar.frame == mapping.map(layout.address))
        let back = try #require(row.backButton)
        #expect(back.alignmentRect(forFrame: back.frame) == mapping.map(layout.navigation[0]))
        #expect(back.translatesAutoresizingMaskIntoConstraints && row.addressBar.translatesAutoresizingMaskIntoConstraints)
        #expect(Self.ownConstraints(row).isEmpty)
    }
}
