import AppKit
import CmuxNextTestSupport
import ImageIO
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextUpdater
@testable import CmuxNextSidebar
import CmuxTheme
import Foundation
import Testing

/// Native before/after stills for launch visibility (note: "remove app store for now / Remove what's new?").
/// Every panel starts with the same stored ``SidebarLayoutDocument.defaults`` fixture:
/// ``base`` is the pre-change projection, ``hidden`` is Labs off, and ``labs-on`` is Labs on
/// with the real sidebar's "cmux Updated!" / What's New card. The output is deliberately a
/// test-owned gallery so it can run in a GUI package lane without leasing a live app window.
@MainActor @Suite(.serialized, .closesItsWindows) struct LaunchPolishVisibilityGalleryTests {
    enum Variant: String, CaseIterable {
        case base
        case hidden
        case labsOn = "labs-on"
    }

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func projection(_ variant: Variant) -> SidebarLayoutDocument {
        let stored = SidebarLayoutDocument.defaults
        switch variant {
        case .base: return SidebarRows.visibleLayout(stored)
        case .hidden: return SidebarRows.visibleLayout(stored, showAppStore: false)
        case .labsOn: return SidebarRows.visibleLayout(stored, showAppStore: true)
        }
    }

    static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let workspace = SidebarWorkspace(id: WorkspaceID("launch-polish-gallery"), title: "Launch polish")
        let top = SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue,
                                                                      title: "", showsTitle: false)), nodes: [])
        return [top, SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])]
    }

    static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let document = projection(variant)
        let model = SidebarModel(sections: sections())
        model.layout = document
        model.itemInfo = SidebarBridge.itemInfo(for: document, registered: { _ in true })
        model.updatedCard = variant == .hidden
            ? nil
            : SidebarUpdatedCard(title: UpdaterService.updatedCardTitle,
                                 whatsNewTitle: UpdaterService.updatedCardWhatsNewTitle,
                                 dismissLabel: UpdaterService.updatedCardDismissLabel)

        let width: CGFloat = 300, height: CGFloat = 560
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = sidebar
        let theme = dark ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(sidebar) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds))
        sidebar.cacheDisplay(in: sidebar.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = Self.packageRoot.appending(path: ".build/launch-polish-visibility-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var sheets: [CGImage] = []
        for variant in Variant.allCases {
            let image = try Self.render(variant, dark: true)
            sheets.append(image)
            try Self.write(image, to: out.appending(path: "\(variant.rawValue).png"))
        }
        let gap = 16
        let width = sheets.reduce(0) { $0 + $1.width } + gap * (sheets.count - 1)
        let height = sheets.map(\.height).max() ?? 0
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for image in sheets {
            ctx.draw(image, in: CGRect(x: x, y: 0, width: image.width, height: image.height))
            x += image.width + gap
        }
        try Self.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = out.deletingLastPathComponent()
        tar.arguments = ["cf", "launch-polish-visibility-gallery.tar", out.lastPathComponent]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
