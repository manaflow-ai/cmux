import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import ImageIO
import Testing

/// Native stills for the pane creation controls. The first frame is the existing compact plus;
/// the next two show the pane's type affordance and the persistent creation actions.
@MainActor @Suite(.serialized, .closesItsWindows) struct PaneDiscoverabilityGalleryTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private enum Variant: String, CaseIterable {
        case baseline = "01-baseline"
        case chevron = "02-chevron-menu"
        case persistent = "03-persistent-actions"

        var title: String {
            switch self {
            case .baseline: "Baseline · compact +"
            case .chevron: "Pane types · + chevron"
            case .persistent: "Pane types · visible actions"
            }
        }

        var opensMenu: Bool { self != .baseline }
        var showsActions: Bool { self == .persistent }
    }

    private static func render(_ variant: Variant) throws -> CGImage {
        _ = NSApplication.shared
        let animationsEnabled = DesignSettings.shared.animationsEnabled
        DesignSettings.shared.animationsEnabled = false
        defer { DesignSettings.shared.animationsEnabled = animationsEnabled }
        let size = NSSize(width: 900, height: 190)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let scope = ThemeScope(level: .room)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground }.cgColor
        window.contentView = root

        let heading = NSTextField(labelWithString: variant.title)
        heading.font = Typography.bodyEmphasized
        heading.textColor = scope.perform { Palette.textPrimary }
        heading.frame = NSRect(x: 24, y: 154, width: 500, height: 20)
        root.addSubview(heading)

        let tabs = [
            TabItem(id: TabID("chat"), title: "Chat", icon: .symbol("message")),
            TabItem(id: TabID("terminal"), title: "Terminal", icon: .symbol("terminal")),
        ]
        let model = TabStripModel(tabs: tabs, selectedID: tabs[0].id)
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let pane = PaneContentView(stripModel: model, reveal: reveal)
        pane.frame = NSRect(x: 24, y: 22, width: 852, height: 122)
        pane.stripView.opensNewTabMenuOnPress = variant.opensMenu
        let registry = ActionRegistry.standard()
        pane.stripView.contextMenuProvider = { _ in
            let target = ActionTargetRef(kind: .pane, id: "gallery-pane")
            return registry.makePaneCreationMenu(target: target)
        }
        if variant != .baseline {
            let target = variant.showsActions ? ActionTargetRef(kind: .pane, id: "gallery-pane") : nil
            let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { pane.stripView.contextMenuProvider?(.newTabButton) }, paneTarget: target)
            toolbar.update(target: "gallery-terminal", kind: .terminal, paneKinds: [.terminal])
            pane.toolbar = toolbar
        }
        root.addSubview(pane)

        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        pane.stripView.layoutSubtreeIfNeeded()
        pane.toolbar?.view.layoutSubtreeIfNeeded()
        // Window attachment and strip layout reread/reset the pointer. Show every variant with
        // the same pointer-in-strip state only after those passes, with motion settled above.
        pane.stripView.buttonReveal.pointerInStrip = true
        let plus = pane.stripView.newTabButton
        plus.needsLayout = true
        plus.layoutSubtreeIfNeeded()
        // These native glyphs are drawn by updateLayer; a synchronous layer-tree render does
        // not wait for AppKit's next display turn to initialize their colors.
        plus.updateLayer()
        try #require(pane.stripView.alphaValue == 1, "gallery must capture the revealed tab strip")
        try #require(!plus.isHiddenOrHasHiddenAncestor && plus.alphaValue == 1, "gallery must show the creation button")
        try #require(plus.bounds.width > 0 && plus.bounds.height > 0)
        let glyph = try #require(plus.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        try #require(glyph.path != nil && glyph.strokeColor != nil, "gallery must draw the production plus/chevron glyph")
        root.displayIfNeeded()
        CATransaction.flush()
        let scale: CGFloat = 2
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        try #require(root.layer).render(in: context)
        return try #require(context.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderBeforeAfterGallery() throws {
        let root = Self.packageRoot
        let out = root.appending(path: "pane-discoverability-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let images = try Variant.allCases.map { (variant: $0, image: try Self.render($0)) }
        for (variant, image) in images { try Self.write(image, to: out.appending(path: "\(variant.rawValue).png")) }

        let gap = 20, width = images[0].image.width, height = images[0].image.height
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: images.count * height + (images.count + 1) * gap,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.05, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: context.height))
        for (index, entry) in images.enumerated() { context.draw(entry.image, in: CGRect(x: 0, y: gap + (images.count - index - 1) * (height + gap), width: width, height: height)) }
        try Self.write(try #require(context.makeImage()), to: out.appending(path: "all.png"))
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
