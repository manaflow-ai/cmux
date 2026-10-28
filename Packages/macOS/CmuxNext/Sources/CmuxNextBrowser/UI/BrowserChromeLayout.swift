import CoreGraphics
import CmuxNextDesign

// The browser pane's chrome lays out with frames, from pure functions of its
// size and content, as Chrome's views do in `Layout()`
// (chrome/browser/ui/views/toolbar/toolbar_view.cc `ToolbarView::Layout`,
// chrome/browser/ui/views/location_bar/location_bar_view.cc
// `LocationBarView::Layout`). No Auto Layout solve runs for the toolbar row
// on a resize, a tab switch or a toolbar hide (p03-rendering.md R4).
//
// Every rect here is top-down (y grows toward the bottom edge) and
// leading-first (x grows toward the trailing edge). `ChromeFrameMapping`
// turns them into a view's own coordinates: y up unless the view is
// flipped, x mirrored in a right-to-left layout.

/// The token sizes the browser chrome's rows lay out with (density, scale).
nonisolated struct BrowserChromeRowMetrics: Equatable, Sendable {
    var toolbarHeight: CGFloat
    var progressThickness: CGFloat
}

/// The rows of a browser pane, top-down: toolbar, accessory bar (the
/// bookmarks bar), the band the pane frames its tab strip on, and the page.
/// With the toolbar at the bottom the same rows are mirrored, the page on top.
nonisolated struct BrowserChromeLayout: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        var size: CGSize
        var position: ToolbarPosition
        /// 0 while the toolbar is hidden (fullscreen page, Toggle Omnibar).
        var toolbarHeight: CGFloat
        /// 0 while hidden or without an accessory view.
        var accessoryHeight: CGFloat
        var bandHeight: CGFloat
        var progressThickness: CGFloat
    }

    var toolbar: CGRect
    /// Zero high: the edge between the toolbar and the rows after it.
    var separator: CGRect
    var accessoryBar: CGRect
    var band: CGRect
    var content: CGRect
    /// Along the toolbar's page-side edge, inside the toolbar.
    var progressLine: CGRect

    init(_ input: Input) {
        let width = max(0, input.size.width), height = max(0, input.size.height)
        let toolbarHeight = max(0, input.toolbarHeight), accessory = max(0, input.accessoryHeight)
        let band = max(0, input.bandHeight), progress = max(0, input.progressThickness)
        func row(_ y: CGFloat, _ rowHeight: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: width, height: rowHeight) }
        let header = toolbarHeight + accessory + band
        switch input.position {
        case .top:
            toolbar = row(0, toolbarHeight)
            separator = row(toolbarHeight, 0)
            accessoryBar = row(toolbarHeight, accessory)
            self.band = row(toolbarHeight + accessory, band)
            content = row(header, max(0, height - header))
            progressLine = row(toolbarHeight - progress, progress)
        case .bottom:
            let toolbarTop = height - toolbarHeight
            toolbar = row(toolbarTop, toolbarHeight)
            separator = row(toolbarTop, 0)
            accessoryBar = row(toolbarTop - accessory, accessory)
            self.band = row(toolbarTop - accessory - band, band)
            content = row(0, max(0, height - header))
            progressLine = row(toolbarTop, progress)
        }
    }
}

/// One omnibar row: navigation buttons at the leading end, the omnibar, and
/// (in a browser tab) the extension slot and the toolbar buttons at the
/// trailing end. The omnibar takes what is left (`BrowserToolbarLayout`
/// collapses the row first so it keeps its minimum).
nonisolated struct ToolbarRowLayout: Equatable, Sendable {
    struct Metrics: Equatable, Sendable {
        var inset: CGFloat
        var barMargin: CGFloat
        var buttonSpacing: CGFloat
        var buttonSize: CGFloat
        /// The omnibar's distance from the row's toolbar edge (the top, or
        /// the bottom with the toolbar at the bottom).
        var barTop: CGFloat
        var barHeight: CGFloat
    }

    /// The extension slot and the toolbar buttons after the omnibar.
    struct Trailing: Equatable, Sendable {
        var slotWidth: CGFloat
        var buttonsWidth: CGFloat
    }

    struct Input: Equatable, Sendable {
        var size: CGSize
        var position: ToolbarPosition
        /// Shown navigation buttons (Back, Forward, Reload; Forward hides first).
        var navigationButtons: Int
        var trailing: Trailing?
        var metrics: Metrics
    }

    /// One rect per shown navigation button, in order.
    var navigation: [CGRect]
    var address: CGRect
    /// `.zero` without `trailing`.
    var slot: CGRect
    var buttons: CGRect

    init(_ input: Input) {
        let m = input.metrics
        let width = max(0, input.size.width)
        let barY = input.position == .top ? m.barTop : input.size.height - m.barTop - m.barHeight
        let buttonY = barY + (m.barHeight - m.buttonSize) / 2
        let count = max(0, input.navigationButtons)
        navigation = (0..<count).map { index in
            CGRect(x: m.inset + CGFloat(index) * (m.buttonSize + m.buttonSpacing), y: buttonY, width: m.buttonSize, height: m.buttonSize)
        }
        let addressX = navigation.last.map { $0.maxX + m.barMargin } ?? m.inset
        let addressEnd: CGFloat
        if let trailing = input.trailing {
            let buttonsX = width - m.inset - trailing.buttonsWidth
            let slotX = buttonsX - m.buttonSpacing - trailing.slotWidth
            buttons = CGRect(x: buttonsX, y: buttonY, width: trailing.buttonsWidth, height: m.buttonSize)
            slot = CGRect(x: slotX, y: buttonY, width: trailing.slotWidth, height: m.buttonSize)
            addressEnd = slotX - m.barMargin
        } else {
            buttons = .zero
            slot = .zero
            addressEnd = width - m.inset
        }
        address = CGRect(x: addressX, y: barY, width: max(0, addressEnd - addressX), height: m.barHeight)
    }
}
