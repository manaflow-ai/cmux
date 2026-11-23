import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of Subtle Tone's two-tone frame with the gooey tabs (`appearance.titleAreaTone` Subtle Tone, the flush
/// corner `goo`), for Leo, 2026-11-23: "refine my two-tone thing and my gooey tabs thing. proper contrast that is
/// only as contrasty as necessary and probably not much more to not fuck up themes and bgs, and then simply properly
/// unifying the transparency and/or translucency and/or highlighting of the gooey things so that it all looks
/// consistent and good".
///
/// A real window (`SidebarMultiViewWindowTests.Fixture`: sidebar, titlebar, the main pane's card) whose shown
/// workspace has one pane of 12 tabs with long titles, the second selected; one tab mid-drag (lifted and moved along
/// the bar), one multi-selected and one hovered. Each theme × backdrop (opaque, a translucent window over a stand-in
/// desktop gradient, the Starry Night background picture) × main pane width (280, 500, 800 pt).
///
/// Reads no frame-tone API, so the same file draws the base build's "before". Written under
/// `two-tone-gooey-gallery/` as `<theme>-<backdrop>-<width>.png`, a sheet per theme (`sheet-<theme>.png`: a row per
/// backdrop, a column per width) and `pixels.txt` (the card's and the frame's pixel and their OKLCH lightness step),
/// bundled to `two-tone-gooey-gallery.tar` for `cmux-ci run --artifact`. `CMUX_TEST_REQUIRE_GUI=1`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AATwoToneGooeyGalleryTests {
    static let themes: [(file: String, name: String)] = [
        ("default-dark", "Apple System Colors"),
        ("default-light", "Apple System Colors Light"),
        ("solarized-light", "iTerm2 Solarized Light"),
        ("catppuccin-latte", "Catppuccin Latte"),
        ("tokyo-night", "TokyoNight"),
        ("zenburn", "Zenburn"),
        ("olive-grey", "Olive Grey"),
    ]

    enum Backdrop: String, CaseIterable {
        case opaque
        case translucent
        case picture
    }

    static let widths: [CGFloat] = [280, 500, 800]
    static let height: CGFloat = 300

    static let titles = [
        "Claude Code: refactor the frame tone into one material",
        "bun test --watch packages/webviews/src/gallery",
        "Codex: why does the sidebar shade drift on resize",
        "~/code/cmux — zsh — cargo test -p cmux-config",
        "localhost:5173/settings/appearance/title-area",
        "FrameTone.swift — Packages/macOS/CmuxNext",
        "git log --oneline origin/feat-cmux-next..HEAD",
        "Claude Code: review the gooey tab fillets",
        "htop — 128 tasks, load average 3.41 2.97",
        "docs/design/design-system-decisions.md",
        "ssh lane-vm-07 — tail -f /var/log/cmux-ci.log",
        "Codex: capture before and after galleries",
    ]
    static let selectedIndex = 1, draggedIndex = 3, multiIndex = 5, hoveredIndex = 7

    /// Subtle Tone with the gooey flush corner at Default density for `body`, put back after.
    static func withSubtleGoo<T>(_ body: () async throws -> T) async rethrows -> T {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.titleAreaTone, design.tabBarPosition)
        design.densityTokens = DensityPreset.cozy.tokens
        design.titleAreaTone = .subtleTone
        design.tabBarPosition = .top
        let store = TunableStore.shared
        store.register([CornerFlush.tunable.descriptor])
        if !store.isActive { store.activate(file: nil) }
        let flush = store.set(CornerFlush.tunable.key, .choice(CornerFlush.goo.rawValue))
        defer {
            _ = store.set(CornerFlush.tunable.key, flush)
            (design.densityTokens, design.titleAreaTone, design.tabBarPosition) = saved
        }
        return try await body()
    }

    /// The app theme `name` with `backdrop`, put back after.
    static func inTheme<T>(_ name: String, _ backdrop: Backdrop, _ body: () async throws -> T) async throws -> T {
        let original = ThemeScope.app.store.input
        let originalSelection = ThemeScope.app.backdropSelection
        defer {
            _ = ThemeScope.app.store.apply(original)
            ThemeScope.app.setBackdropSelection(originalSelection)
        }
        var input = try AANestedGroupsGalleryTests.input(name)
        if backdrop == .translucent {
            input.backgroundOpacity = 0.65
            input.backgroundBlur = 20
        }
        _ = ThemeScope.app.store.apply(input)
        ThemeScope.app.setBackdropSelection(backdrop == .picture ? .art(.vanGoghStarryNight) : nil)
        return try await body()
    }

    /// One workspace whose pane holds the 12 tabs, the second shown.
    static func tree() -> DaemonTree {
        var tree = SidebarMultiViewWindowTests.Fixture.tree(["k0", "k1"])
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), activeTab: selectedIndex, tabs: titles.enumerated().map { index, title in
            TabSnapshot(surface: SurfaceID(rawValue: 10 + UInt64(index)), title: title)
        })
        tree.workspaces[0].screens = [ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])]
        return tree
    }

    /// A stand-in desktop under a translucent window: a soft diagonal gradient, as a blurred wallpaper shows.
    static func desktop(_ ctx: CGContext) {
        let colors = [CGColor(srgbRed: 0.20, green: 0.42, blue: 0.68, alpha: 1), CGColor(srgbRed: 0.83, green: 0.52, blue: 0.33, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: ctx.width, y: ctx.height), options: [])
    }

    struct Shot {
        let image: CGImage
        let report: String
    }

    static func render(width: CGFloat, backdrop: Backdrop) async throws -> Shot {
        let f = try await SidebarMultiViewWindowTests.Fixture(keys: ["k0", "k1"], tree: tree())
        defer { f.close() }
        let window = try #require(f.controller.window)
        let root = f.controller.root
        let dark = ThemeScope.app.tokens.isDark
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.minSize = NSSize(width: 100, height: 100)
        // The main pane `width` wide: the window is the sidebar and the gutters plus it.
        let chrome = window.frame.width - root.contentHost.frame.width
        window.setFrame(NSRect(x: 0, y: 0, width: chrome + width, height: height), display: false)
        root.themeDidChange()
        f.frame()
        try await Task.sleep(for: .milliseconds(200))
        f.frame()

        let source = try #require(f.controller.content?.panes.values.first)
        let strip = source.view.stripView
        strip.windowMain.changed(isMain: true)
        let ids = strip.model.orderedTabs.map(\.id)
        try #require(ids.count == titles.count, "the pane shows \(ids.count) tabs")
        // Mid-drag: the tab lifted and moved 40 pt along its bar (no press, so the selection stays).
        if let cell = strip.cells[ids[draggedIndex]] {
            let frame = strip.tabsClip.convert(cell.frame, to: strip)
            let start = CGPoint(x: frame.midX, y: frame.midY)
            strip.beginDrag(TabStripPress(id: ids[draggedIndex], start: start))
            strip.updateDrag(at: CGPoint(x: start.x + 40, y: start.y), event: nil)
        }
        _ = strip.model.click(ids[multiIndex], .toggle)
        strip.applyMultiSelection()
        strip.setHovered(ids[hoveredIndex])
        f.frame()
        try await Task.sleep(for: .milliseconds(150))
        f.frame()

        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let shot = try #require(rep.cgImage)
        let ctx = try #require(CGContext(data: nil, width: shot.width, height: shot.height, bitsPerComponent: 8,
                                         bytesPerRow: shot.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let surface = root.themeTokens.surfaceBackground.withAlpha(1)
        if backdrop == .translucent {
            desktop(ctx)
        } else {
            ctx.setFillColor(CGColor(srgbRed: surface.red, green: surface.green, blue: surface.blue, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        }
        ctx.draw(shot, in: CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        let image = try #require(ctx.makeImage())

        // The card's pixel (inside the content, under the tab row) and the frame's (the gutter below the card).
        let scale = CGFloat(shot.width) / root.bounds.width
        let bytes = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        func pixel(_ point: CGPoint) -> ThemeRGB {
            let x = min(shot.width - 1, max(0, Int((point.x * scale).rounded(.down))))
            let yFromTop = root.isFlipped ? point.y : root.bounds.height - point.y
            let y = min(shot.height - 1, max(0, Int((yFromTop * scale).rounded(.down))))
            let offset = y * shot.width * 4 + x * 4
            return ThemeRGB(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255, blue: Double(bytes[offset + 2]) / 255)
        }
        let card = root.contentHost.frame
        let cardPoint = CGPoint(x: card.midX, y: root.isFlipped ? card.maxY - 24 : card.minY + 24)
        let framePoint = CGPoint(x: card.midX, y: root.isFlipped ? (card.maxY + root.bounds.maxY) / 2 : card.minY / 2)
        let (c, fr) = (pixel(cardPoint), pixel(framePoint))
        let step = fr.oklch.lightness - c.oklch.lightness
        let report = "card \(ChromeLayerHex.hex(c)) frame \(ChromeLayerHex.hex(fr)) dL \(String(format: "%+.3f", step)) "
            + "(card \(Int(card.width))x\(Int(card.height)) at y \(Int(card.minY)))"
        strip.cancelDrag()
        return Shot(image: image, report: report)
    }

    /// `rows` of images on one sheet, each cell the widest image's width, on a mid grey.
    static func sheet(_ rows: [[CGImage]]) throws -> CGImage {
        let gap = 24
        let cellW = rows.flatMap { $0 }.map(\.width).max() ?? 1
        let cellH = rows.flatMap { $0 }.map(\.height).max() ?? 1
        let columns = rows.map(\.count).max() ?? 1
        let ctx = try #require(CGContext(data: nil, width: columns * cellW + (columns - 1) * gap, height: rows.count * cellH + (rows.count - 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (r, row) in rows.enumerated() {
            for (c, image) in row.enumerated() {
                ctx.draw(image, in: CGRect(x: c * (cellW + gap), y: ctx.height - r * (cellH + gap) - image.height, width: image.width, height: image.height))
            }
        }
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() async throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let packageRoot = AANestedGroupsGalleryTests.packageRoot
        let out = packageRoot.appending(path: "two-tone-gooey-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        try await Self.withSubtleGoo {
            report.append("tone \(DesignSettings.shared.titleAreaTone), flush \(CornerFlush.current), contrast \(DesignSettings.shared.titleAreaContrast)")
            for theme in Self.themes {
                var rows: [[CGImage]] = []
                for backdrop in Backdrop.allCases {
                    var row: [CGImage] = []
                    for width in Self.widths {
                        let shot = try await Self.inTheme(theme.name, backdrop) {
                            try await Self.render(width: width, backdrop: backdrop)
                        }
                        let name = "\(theme.file)-\(backdrop.rawValue)-\(Int(width))"
                        try AAGroupHeaderDensityGalleryTests.write(shot.image, to: out.appending(path: "\(name).png"))
                        report.append("\(name): \(shot.report)")
                        row.append(shot.image)
                    }
                    rows.append(row)
                }
                try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(rows), to: out.appending(path: "sheet-\(theme.file).png"))
            }
        }
        try (report.joined(separator: "\n") + "\n").write(to: out.appending(path: "pixels.txt"), atomically: true, encoding: .utf8)
        print("two-tone-gooey-gallery:\n" + report.joined(separator: "\n"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = packageRoot
        tar.arguments = ["cf", "two-tone-gooey-gallery.tar", "two-tone-gooey-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
