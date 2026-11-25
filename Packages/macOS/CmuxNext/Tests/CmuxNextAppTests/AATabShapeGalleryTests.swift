import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import ImageIO
import Testing

/// The tab shape gallery (`appearance.tabShape`; Leo, 2026-11-18: "the blockiness of tabs both horizontal the the
/// vertical ones in the sidebar should be customized/customizable too. like the "gooey" is each tab looking like it's
/// morphing into the visible pane. the two tone thing."): a window's top-left part built from the app's own views (the
/// sidebar list, a pane's tab strip, the frame's shade and the flush corner's chrome) for the three looks (``Look``):
/// block and rounded (`appearance.tabShape`) and gooey (`appearance.cornerFlush` flush-goo on a block shape),
/// under One Color (the default tone) and Subtle Tone, dark and light. `switch-*.png` and `switch.gif` step the
/// selection through three tabs and three sidebar rows under gooey: the flare moves with the selection and no tab or
/// row moves. Written under `tab-shape-gallery/` with `all.png`, bundled to `tab-shape-gallery.tar` for
/// `cmux-ci run --artifact`. Runs only with `CMUX_TEST_REQUIRE_GUI=1`; the no-jump check runs always.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATabShapeGalleryTests {
    /// The gallery's looks: the two tab shapes, and the goo, which is the flush corner's `flush-goo` (one setting per look).
    enum Look: String, CaseIterable {
        case block, rounded, gooey
        var shape: TabShape { self == .rounded ? .rounded : .block }
        var cornerFlush: CornerFlush? { self == .gooey ? .goo : nil }
    }

    static let width: CGFloat = 760, height: CGFloat = 300, sidebarWidth: CGFloat = 220

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let titles = ["Slimmer CEF bundle", "Tab shapes", "Gooey corners", "Two tones", "Release notes"]
        let rows = titles.enumerated().map { index, title in
            SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("w-\(index)"), title: title, activity: index == 2 ? .busy(progress: nil) : .idle))
        }
        return [SidebarSection(kind: .machine(machine), nodes: rows)]
    }

    struct Scene {
        let window: NSWindow
        let root: NSView
        let strip: TabStripView
        let list: SidebarListView
        let model: SidebarModel
        let chrome: CornerFlushChrome

        func select(_ index: Int) {
            strip.model.selectedID = TabID("tab\(index)")
            strip.syncFromModel()
            model.activeWorkspaceID = WorkspaceID("w-\(index)")
            list.reload(animated: false)
            settle()
        }

        func settle() {
            for _ in 0..<2 {
                strip.needsLayout = true
                root.layoutSubtreeIfNeeded()
                strip.layoutSubtreeIfNeeded()
                list.reportGooeySelection()
            }
            for view in AANestedGroupsGalleryTests.all(root) {
                view.layer?.removeAllAnimations()
                view.needsDisplay = true
                view.displayIfNeeded()
            }
            CATransaction.flush()
        }

        func image() throws -> CGImage {
            let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            return try #require(rep.cgImage)
        }
    }

    /// Builds the scene with `shape` and `tone` set on the shared design settings; the caller restores them.
    static func scene(dark: Bool) throws -> Scene {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.surfaceBackground.withAlphaComponent(1) }.cgColor

        // The frame's shade on the window's backdrop, under the sidebar and the content, as the window root stacks them.
        let shade = MainPaneChromeShadeView(frame: root.bounds)
        root.addSubview(shade)
        let gap = CornerFlush.goo.gap
        let titlebar: CGFloat = 40
        let model = SidebarModel(sections: sections())
        model.activeWorkspaceID = WorkspaceID("w-1")
        let list = SidebarListView(model: model)
        list.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: height - titlebar)
        root.addSubview(list)

        // The content: a pane whose tab strip is the card's top row, its rows below it.
        let scale = window.backingScaleFactor
        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        let content = NSView(frame: NSRect(x: sidebarWidth + gap, y: gap, width: width - sidebarWidth - 2 * gap, height: height - 2 * gap))
        content.wantsLayer = true
        root.addSubview(content)
        let pane = NSView(frame: content.bounds)
        pane.wantsLayer = true
        content.addSubview(pane)
        let tabs = ["shell", "Tab shapes", "browser", "notes"].enumerated().map { TabItem(id: TabID("tab\($0.offset)"), title: $0.element) }
        let strip = TabStripView(model: TabStripModel(tabs: tabs, selectedID: TabID("tab1")))
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: 0, y: pane.bounds.height - stripHeight, width: pane.bounds.width, height: stripHeight)
        pane.addSubview(strip)
        for line in 0..<6 { // the content's text, so the card reads as a pane
            let bar = CALayer()
            bar.frame = CGRect(x: 16, y: pane.bounds.height - stripHeight - 28 - CGFloat(line) * 22, width: CGFloat(220 + (line * 53) % 180), height: 8)
            bar.cornerRadius = 4
            bar.backgroundColor = scope.perform { Palette.textTertiary.withAlphaComponent(0.5) }.cgColor
            pane.layer?.addSublayer(bar)
        }

        let chrome = CornerFlushChrome(frame: .zero)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - titlebar - list.frame.height // the list starts under the titlebar row
        root.layoutSubtreeIfNeeded()
        chrome.apply(content: content, radius: CornerFlush.current.cardRadius, isDark: dark, page: false, shade: shade, in: root)
        let scene = Scene(window: window, root: root, strip: strip, list: list, model: model, chrome: chrome)
        scene.settle()
        chrome.apply(content: content, radius: CornerFlush.current.cardRadius, isDark: dark, page: false, shade: shade, in: root)
        scene.settle()
        return scene
    }

    /// Sets the look and the tone for `body`, at Default density on the stock chrome, and puts them back after.
    static func with<T>(_ look: Look, _ tone: TitleAreaTone, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let before = (design.densityTokens, design.chromeStyle, design.tabShape, design.titleAreaTone, design.titleAreaContrast,
                      design.sidebarSurface, design.tabBarPosition, design.cornerFlush)
        defer {
            (design.densityTokens, design.chromeStyle, design.tabShape, design.titleAreaTone, design.titleAreaContrast,
             design.sidebarSurface, design.tabBarPosition, design.cornerFlush) = before
        }
        design.densityTokens = DensityPreset.cozy.tokens
        design.chromeStyle = .flat
        design.titleAreaContrast = 1
        design.sidebarSurface = .same
        design.tabBarPosition = .top
        design.tabShape = look.shape
        design.cornerFlush = look.cornerFlush
        design.titleAreaTone = tone
        return try body()
    }

    /// Switching tabs under gooey moves only the flare: every tab and sidebar row keeps its frame, and the selected
    /// row is the one that runs into the card (the ui-state-transition rule: no layout jump).
    @Test func switchingUnderGooeyMovesNoTabOrRow() throws {
        try Self.with(.gooey, .oneColor) {
            let scene = try Self.scene(dark: true)
            defer { scene.window.close() }
            let tabFrames = scene.strip.cells.mapValues(\.frame)
            let rowFrames = scene.list.rowViews.mapValues(\.frame)
            for index in [2, 3, 1] {
                scene.select(index)
                #expect(scene.strip.cells.mapValues(\.frame) == tabFrames, "a tab moved on switching to \(index)")
                #expect(scene.list.rowViews.mapValues(\.frame) == rowFrames, "a sidebar row moved on switching to \(index)")
                let selected = try #require(scene.list.rowViews[.workspace(WorkspaceID("w-\(index)"))])
                #expect(selected.runsIntoCard, "the selected row \(index) runs into the card")
                #expect(scene.list.rowViews.values.filter(\.runsIntoCard).count == 1, "only the selected row runs into the card")
            }
        }
    }

    /// Rounded under goo keeps every row and the selected tab capsules: the shape wins over the corner.
    @Test func roundedKeepsCapsulesUnderGoo() throws {
        try Self.with(.rounded, .oneColor) { // `with` puts the corner back too
            DesignSettings.shared.cornerFlush = .goo
            let scene = try Self.scene(dark: true)
            defer { scene.window.close() }
            #expect(scene.list.rowViews.values.allSatisfy { !$0.runsIntoCard })
            #expect(scene.strip.cells[TabID("tab1")]?.runsIntoCard == false)
        }
    }

    @Test func blockAndRoundedNeverRunTheSidebarRowIntoTheCard() throws {
        for look in [Look.block, .rounded] {
            try Self.with(look, .subtleTone) {
                let scene = try Self.scene(dark: false)
                defer { scene.window.close() }
                #expect(scene.list.rowViews.values.allSatisfy { !$0.runsIntoCard }, "\(look)")
                let tab = try #require(scene.strip.cells[TabID("tab1")])
                #expect(tab.runsIntoCard == (look == .block), "\(look): only block's selected tab is a folder under Subtle Tone")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let packageRoot = AANestedGroupsGalleryTests.packageRoot
        let out = packageRoot.appending(path: "tab-shape-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        let tones: [(TitleAreaTone, String)] = [(.oneColor, "one-color"), (.subtleTone, "subtle-tone")]
        for dark in [true, false] {
            for (tone, toneName) in tones {
                for look in Look.allCases {
                    let image = try Self.with(look, tone) {
                        let scene = try Self.scene(dark: dark)
                        defer { scene.window.close() }
                        return try scene.image()
                    }
                    images.append(image)
                    try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(look.rawValue)-\(toneName)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        let columns = Look.allCases.count
        let w = images[0].width, h = images[0].height, gap = 16, rows = images.count / columns
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: rows * h + (rows - 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(image, in: CGRect(x: col * (w + gap), y: (rows - 1 - row) * (h + gap), width: w, height: h))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))

        // Switching under gooey, dark: each step's still, and the steps as a looping GIF.
        for dark in [true, false] {
            let frames: [CGImage] = try Self.with(.gooey, .oneColor) {
                let scene = try Self.scene(dark: dark)
                defer { scene.window.close() }
                var frames: [CGImage] = []
                for index in [1, 2, 3, 2, 1] {
                    scene.select(index)
                    frames.append(try scene.image())
                }
                return frames
            }
            let mode = dark ? "dark" : "light"
            for (step, frame) in frames.enumerated() {
                try AAGroupHeaderDensityGalleryTests.write(frame, to: out.appending(path: "switch-\(mode)-\(step).png"))
            }
            let gif = out.appending(path: "switch-\(mode).gif")
            let dest = try #require(CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, frames.count, nil))
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for frame in frames {
                CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.8]] as CFDictionary)
            }
            #expect(CGImageDestinationFinalize(dest))
        }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = packageRoot
        tar.arguments = ["cf", "tab-shape-gallery.tar", "tab-shape-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
