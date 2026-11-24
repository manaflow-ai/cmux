import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Evidence only (not landed): the browser pane's tab row (a tab, the hovered `+ ⌄`, a pinned tool and Exit Zoom)
/// over its toolbar (arrows, reload, omnibar, ⋮) at every density, light and dark, with each button's frame outlined
/// in red and the tab pill's in blue, written to `.build/tab-row-button-sizes/`.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabRowButtonSizeShotTests {
    @Test func renderEveryDensityLightAndDark() throws {
        let out = ShotContactSheet.packageRoot.appending(path: ".build/tab-row-button-sizes")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let design = DesignSettings.shared
        let saved = design.densityTokens
        defer { design.densityTokens = saved }
        for dark in [false, true] {
            var shots: [(String, CGImage)] = []
            for preset in DensityPreset.allCases {
                design.densityTokens = preset.tokens
                let (image, line) = try render(dark: dark)
                shots.append(("\(preset.rawValue): \(line)", image))
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: out.appending(path: "\(preset.rawValue)-\(dark ? "dark" : "light").png"))
            }
            let sheet = try #require(NSBitmapImageRep(cgImage: ShotContactSheet.image(shots)).representation(using: .png, properties: [:]))
            try sheet.write(to: out.appending(path: "sheet-\(dark ? "dark" : "light").png"))
        }
        print("tab-row-button-sizes: wrote \(out.path)")
    }

    private func render(dark: Bool) throws -> (CGImage, String) {
        let width: CGFloat = 460
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let root = FlippedRoot(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        root.wantsLayer = true
        root.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
        window.contentView = root

        let stripHeight = Metrics.tabStripHeight
        let toolsWidth: CGFloat = 90
        let model = TabStripModel(tabs: [TabItem(id: TabID("shot"), title: "Example Domain")], selectedID: TabID("shot"))
        let strip = TabStripView(model: model)
        strip.showsNewTabMenuButton = true
        strip.frame = CGRect(x: 0, y: 0, width: width - toolsWidth, height: stripHeight)
        root.addSubview(strip)
        strip.sync(fromModel: true, animating: false)
        strip.layoutSubtreeIfNeeded()
        strip.newTabButton.isHovered = true

        let tools = PaneToolbarView(frame: CGRect(x: width - toolsWidth, y: 0, width: toolsWidth, height: stripHeight))
        root.addSubview(tools)
        tools.show([PaneToolbarItem(id: "pin", title: "Pin", symbol: "pin", shortcut: nil)], zoomed: true)
        tools.layoutSubtreeIfNeeded()

        let tab = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com")))
        let chrome = BrowserChromeView(tab: tab)
        chrome.frame = NSRect(x: 0, y: stripHeight, width: width, height: 200 - stripHeight)
        root.addSubview(chrome)
        root.layoutSubtreeIfNeeded()
        chrome.layoutSubtreeIfNeeded()

        let cell = try #require(strip.cells[TabID("shot")])
        let pill = root.convert(cell.frame, from: strip.tabsClip)
        var buttons: [NSView] = [strip.newTabButton, strip.newTabMenuButton, tools.zoomButton] + tools.buttons
        buttons += [chrome.backButton, chrome.forwardButton, chrome.reloadButton]
        if let more = chrome.toolbarButtons.anchor(for: .overflow) { buttons.append(more) }
        let overlay = CALayer()
        overlay.frame = root.bounds
        root.layer?.addSublayer(overlay)
        func outline(_ rect: CGRect, _ color: NSColor) {
            let box = CALayer()
            box.frame = rect.insetBy(dx: 0.25, dy: 0.25)
            box.borderColor = color.cgColor
            box.borderWidth = 0.5
            overlay.addSublayer(box)
        }
        outline(pill, .systemBlue)
        for button in buttons where !button.isHiddenOrHasHiddenAncestor { outline(root.convert(button.bounds, from: button), .systemRed) }
        let plus = strip.newTabButton.frame.size
        let line = "tab \(fmt(pill.height)) · + \(fmt(plus.width))×\(fmt(plus.height)) · Exit Zoom \(fmt(tools.zoomButton.frame.height))"
            + " · toolbar \(fmt(OmnibarStyle.buttonSize))"

        let height = min(200, chrome.convert(chrome.addressBar.bounds, from: chrome.addressBar).maxY + stripHeight + 12)
        let scale: CGFloat = 2
        let context = try #require(CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        try #require(root.layer).render(in: context)
        defer { tab.close() }
        return (try #require(context.makeImage()), line)
    }

    private func fmt(_ value: CGFloat) -> String { value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value) }
}

private final class FlippedRoot: NSView {
    override var isFlipped: Bool { true }
}
