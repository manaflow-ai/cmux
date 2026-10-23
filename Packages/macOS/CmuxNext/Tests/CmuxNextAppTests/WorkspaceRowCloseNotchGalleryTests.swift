import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// The row close corner's gallery (`sidebar.closeNotch`, Leo 2026-10-22): every look, a hovered row and
/// a hovered selected row, light and dark, drawn from the real list offscreen with the shipped Soft Blue
/// themes. Written as PNGs under `close-notch-gallery/` in the package and bundled to
/// `close-notch-gallery.tar` for `cmux-ci run --artifact`.
///
/// Hosted preview recipe (no local native build): when a managed fleet script is
/// configured for this suite, it runs
/// `CMUX_TEST_REQUIRE_GUI=1 CMUX_SOURCE_SHA=<40-char-sha> swift test --skip-build --filter WorkspaceRowCloseNotchGalleryTests`
/// from `Packages/macOS/CmuxNext` and can return `close-notch-gallery.tar` as an artifact. The manifest
/// and contact sheet inside the archive make the exact matrix easy to inspect without guessing a filename.
@MainActor @Suite(.serialized) struct WorkspaceRowCloseNotchGalleryTests {
    static let titles = ["Release checklist", "a workspace whose name runs to the end of its row", "Notes"]

    /// The source revision is supplied by the hosted runner (`CMUX_SOURCE_SHA`), then by Actions when
    /// this suite is run in CI. Keeping it in the artifact prevents a still from being mistaken for a
    /// newer working tree when a developer has several previews open.
    static var sourceRevision: String {
        for key in ["CMUX_SOURCE_SHA", "GITHUB_SHA", "HEAD_SHA"] {
            if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
        }
        return "unknown"
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// A compact filmstrip for quick human review. Individual files remain the source of truth and the
    /// manifest maps every cell to its look/state/theme, so the sheet never replaces a matrix case.
    static func contactSheet(_ images: [(name: String, image: CGImage)]) throws -> CGImage {
        let columns = 4
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let cellWidth = images.map(\.image.width).max() ?? 0
        let cellHeight = images.map(\.image.height).max() ?? 0
        let gutter = 8
        let context = try #require(CGContext(data: nil, width: columns * cellWidth + (columns + 1) * gutter,
                                              height: rows * cellHeight + (rows + 1) * gutter,
                                              bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        for (index, entry) in images.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = gutter + column * (cellWidth + gutter)
            let y = context.height - gutter - (row + 1) * cellHeight - row * gutter
            context.draw(entry.image, in: CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
        }
        return try #require(context.makeImage())
    }

    static func render(_ look: SidebarCloseNotch, hoverSelected: Bool, theme: String, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        try #require(TunableStore.shared.set(SidebarCloseNotch.tunable.key, look.tunableValue) == look.tunableValue)
        // The watch drops its cached values one main-actor hop after a set; rows made in this turn
        // would read the last look.
        SidebarTunablesWatch.shared.changed()
        let width: CGFloat = 240, height: CGFloat = 120
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeStore.shared.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let workspaces = titles.enumerated().map { SidebarWorkspace(id: WorkspaceID("ws-\($0.offset)"), title: $0.element) }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let list = SidebarListView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })]))
        list.contextMenuProvider = { _ in NSMenu() }
        list.frame = NSRect(x: 0, y: 0, width: width, height: height)
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.frame.origin.y = height - list.frame.height
        let selected = try #require(list.rowViews[.workspace(workspaces[0].id)])
        selected.isSelected = true
        let hovered = workspaces[hoverSelected ? 0 : 1].id
        list.setHovered(.workspace(hovered))
        root.layoutSubtreeIfNeeded()
        let row = try #require(list.rowViews[.workspace(hovered)] as? WorkspaceRowView)
        try #require(row.closeNotchLook == look && row.closeNotch == look, "the \(look) still draws the \(row.closeNotchLook) cut")
        for view in AANestedGroupsGalleryTests.all(root) { view.needsDisplay = true; view.displayIfNeeded() }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    /// Runs only with `CMUX_TEST_REQUIRE_GUI` set (the fleet's opt-in for drawing tests): it writes files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        defer {
            TunableStore.shared.set(SidebarCloseNotch.tunable.key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "close-notch-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [(name: String, image: CGImage)] = []
        var entries: [[String: Any]] = []
        for look in SidebarCloseNotch.allCases {
            for (state, hoverSelected) in [("hover", false), ("selected-hover", true)] {
                for (mode, theme, dark) in [("light", "Soft Blue Light", false), ("dark", "Soft Blue", true)] {
                    let image = try Self.render(look, hoverSelected: hoverSelected, theme: theme, dark: dark)
                    let filename = "\(look.rawValue)-\(state)-\(mode).png"
                    try Self.writePNG(image, to: out.appending(path: filename))
                    images.append((filename, image))
                    entries.append(["file": filename, "look": look.rawValue, "state": state, "theme": theme,
                                    "mode": mode, "width": image.width, "height": image.height])
                }
            }
        }
        try Self.writePNG(try Self.contactSheet(images), to: out.appending(path: "contact-sheet.png"))
        let manifest: [String: Any] = [
            "schema_version": 1,
            "source_sha": Self.sourceRevision,
            "fixture": "sidebar.closeNotch",
            "looks": SidebarCloseNotch.allCases.map(\.rawValue),
            "states": ["hover", "selected-hover"],
            "modes": ["light", "dark"],
            "entries": entries,
            "contact_sheet": "contact-sheet.png",
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: out.appending(path: "manifest.json"), options: .atomic)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "close-notch-gallery.tar", "close-notch-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
