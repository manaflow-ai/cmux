import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Stills of the workspace hover card (Lawrence msg 19245, "alignment here looks bad ... not showing enough
/// details per each") over `WorkspaceHoverCardFixture`, the real card view on the real overlay glass, over a
/// busy terminal, dark and light. Written under `hover-card-variants/`, bundled to `hover-card-variants.tar`
/// for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAWorkspaceHoverCardVariantsGalleryTests {
    static let canvas = NSSize(width: 340, height: 440)

    static func render(dark: Bool, make: () -> WorkspaceHoverCardView) throws -> CGImage {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: canvas), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = BusyBackdrop(frame: NSRect(origin: .zero, size: canvas))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        // Fixed colors: a dynamic palette color resolves in the process's (light) appearance inside the image.
        root.ink = dark ? NSColor(srgbRed: 0.85, green: 0.87, blue: 0.92, alpha: 1) : NSColor(srgbRed: 0.15, green: 0.16, blue: 0.2, alpha: 1)
        root.fill = dark ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 1) : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        let card = make()
        let host = HoverCardGalleryHost(body: card) { [weak card] in card?.applyColors() }
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            host.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
        ])
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        card.applyColors()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        // The card alone, laid on the backdrop drawn straight into the still: a cached display of the root
        // drew its own backdrop blank.
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let shot = try #require(rep.cgImage)
        let scale = CGFloat(shot.width) / max(host.bounds.width, 1)
        let ctx = try #require(CGContext(data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: scale, y: scale)
        root.backdropImage().draw(in: NSRect(origin: .zero, size: canvas))
        NSGraphicsContext.restoreGraphicsState()
        let frame = host.frame
        let y = root.isFlipped ? canvas.height - frame.maxY : frame.minY
        ctx.draw(shot, in: CGRect(x: frame.minX * scale, y: y * scale, width: CGFloat(shot.width), height: CGFloat(shot.height)))
        return try #require(ctx.makeImage())
    }

    /// One gallery variant: its label and the style the real card view takes.
    struct Variant {
        let id: String
        let summary: String
        let style: WorkspaceTabHoverCardStyle
    }

    static let variants: [Variant] = {
        typealias S = WorkspaceTabHoverCardStyle
        func v(_ id: String, _ summary: String, _ edit: (inout S) -> Void) -> Variant {
            var style = S()
            edit(&style)
            return Variant(id: id, summary: summary, style: style)
        }
        return [
            v("V1", "two lines: place · state · time, frosted (default)") { _ in },
            v("V2", "V1 on the glass") { $0.material = .glass },
            v("V3", "two lines: kind · place · branch, time column") { $0.detail = [.kind, .place, .branch]; $0.trailing = .time },
            v("V4", "one line: title then place, time column, 6 rows") {
                $0.twoLines = false; $0.detail = [.place]; $0.trailing = .time; $0.rowLimit = 6
            },
            v("V5", "one line: title then place, state column, 8 rows") {
                $0.twoLines = false; $0.detail = [.place]; $0.trailing = .state; $0.rowLimit = 8
            },
            v("V6", "grouped by kind, two lines, 6 rows") { $0.groupsByKind = true; $0.rowLimit = 6 },
            v("V7", "summary header, place · branch, time column") {
                $0.header = .summary; $0.detail = [.place, .branch]; $0.trailing = .time
            },
            v("V8", "status first: state · time · place, tinted") { $0.detail = [.state, .time, .place]; $0.tintsState = true },
            v("V9", "grouped, one line, time column, 8 rows") {
                $0.groupsByKind = true; $0.twoLines = false; $0.detail = [.place]; $0.trailing = .time; $0.rowLimit = 8
            },
            v("V10", "summary header, kind · place, state column, glass") {
                $0.header = .summary; $0.detail = [.kind, .place]; $0.trailing = .state; $0.material = .glass
            },
            v("V11", "everything: place · branch · state · time, tinted") {
                $0.detail = [.place, .branch, .state, .time]; $0.tintsState = true
            },
            v("V12", "one line: kind, time column, glass, 6 rows") {
                $0.twoLines = false; $0.detail = [.kind]; $0.trailing = .time; $0.material = .glass; $0.rowLimit = 6
            },
        ]
    }()

    static func card(_ style: WorkspaceTabHoverCardStyle) -> WorkspaceHoverCardView {
        let card = WorkspaceHoverCardView(style: style)
        card.configure(WorkspaceHoverCardFixture.content, now: WorkspaceHoverCardFixture.now)
        card.configureTabs(title: WorkspaceHoverCardFixture.title, tabs: WorkspaceHoverCardFixture.tabs, now: WorkspaceHoverCardFixture.now)
        return card
    }

    /// `image` with `label` in a band on its top-left (the variant's name on its own still).
    static func labeled(_ image: CGImage, _ label: String, dark: Bool) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let scale = CGFloat(image.width) / canvas.width
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: scale, y: scale)
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: dark ? NSColor.black : NSColor.white,
        ])
        let size = text.size()
        let band = CGRect(x: 8, y: canvas.height - 8 - size.height - 6, width: size.width + 12, height: size.height + 6)
        ctx.setFillColor((dark ? NSColor(white: 0.95, alpha: 1) : NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.3, alpha: 1)).cgColor)
        ctx.fill(band)
        text.draw(at: NSPoint(x: band.minX + 6, y: band.minY + 3))
        NSGraphicsContext.restoreGraphicsState()
        return try #require(ctx.makeImage())
    }

    /// The stills in a grid, `columns` wide, dark block above the light one.
    static func sheet(_ dark: [CGImage], _ light: [CGImage], columns: Int) throws -> CGImage {
        let w = dark[0].width, h = dark[0].height, gap = 16
        let rows = (dark.count + columns - 1) / columns
        let width = columns * w + (columns - 1) * gap, height = 2 * rows * h + (2 * rows - 1) * gap + gap * 2
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (block, images) in [dark, light].enumerated() {
            for (i, image) in images.enumerated() {
                let row = block * rows + i / columns, col = i % columns
                let top = row * (h + gap) + (block == 1 ? gap * 2 : 0)
                ctx.draw(image, in: CGRect(x: col * (w + gap), y: height - top - h, width: w, height: h))
            }
        }
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "hover-card-variants")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out.appending(path: "before-after"), withIntermediateDirectories: true)
        var shots: [Bool: [CGImage]] = [true: [], false: []]
        for dark in [true, false] {
            let appearance = dark ? "dark" : "light"
            for variant in Self.variants {
                let image = try Self.labeled(try Self.render(dark: dark) { Self.card(variant.style) },
                                             "\(variant.id)  \(variant.summary)", dark: dark)
                shots[dark]?.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(variant.id.lowercased())-\(appearance).png"))
            }
            // The shipped card (the default style), for the before/after pair.
            let after = try Self.render(dark: dark) { Self.card(.standard) }
            try AAGroupHeaderDensityGalleryTests.write(after, to: out.appending(path: "before-after/after-\(appearance).png"))
        }
        try AAGroupHeaderDensityGalleryTests.write(try Self.sheet(shots[true] ?? [], shots[false] ?? [], columns: 4),
                                                   to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "hover-card-variants.tar", "hover-card-variants"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}

/// A terminal's worth of text behind the card: what a hover card covers while the person works.
private final class BusyBackdrop: NSView {
    var ink: NSColor = .labelColor
    /// The backdrop image's background.
    var fill: NSColor = .windowBackgroundColor
    override var isFlipped: Bool { true }

    /// The terminal text on the theme's background, as an image.
    func backdropImage() -> NSImage {
        NSImage(size: bounds.size, flipped: true) { [ink, fill] rect in
            fill.setFill()
            rect.fill()
            let lines = [
                "$ swift test --filter WorkspaceTabHoverCardTests", "Building for debugging...",
                "[312/1290] Compiling CmuxNextSidebar WorkspaceHoverCard.swift", "warning: var 'x' was never mutated",
                "Test Suite 'WorkspaceTabHoverCardTests' started", "✔ Test clickingAnInactiveWorkspaceTab passed (0.21s)",
                "✔ Test cardStartsWithTabsAndCollapsedDetails passed", "git log --oneline -5", "d4773687fb62 cmux NEXT: name Cmd-N chat",
                "0ffea12ac93f fix(sidebar): stable drop overlay", "~/fun/cmux on feat-cmux-next [!?] via 🦀 1.88",
            ]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ink.withAlphaComponent(0.85),
            ]
            var y: CGFloat = 4
            var index = 0
            while y < rect.height {
                (lines[index % lines.count] as NSString).draw(at: NSPoint(x: 8, y: y), withAttributes: attributes)
                y += 15
                index += 1
            }
            return true
        }
    }
}
