import AppKit
import CmuxNextDesign
@testable import CmuxNextServer
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// The right sidebar's Machines section in each ``MachineSectionStyle`` (cloud sidebar redesign,
/// ask-2663fecb03), dark and light, with this Mac and the sample machines
/// (``MachineSectionRow/fixtures``). `CMUX_TEST_REQUIRE_GUI=1`; writes PNGs under
/// `machines-section-gallery/` and `machines-section-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.closesItsWindows, .serialized) struct AAMachineSectionGalleryTests {
    static func render(_ style: MachineSectionStyle, appearance: NSAppearance.Name) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 280, height: CGFloat = 400
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        // The shipped Soft Blue themes, as the sidebar galleries draw: the inks come from the theme.
        let theme = appearance == .darkAqua ? "Soft Blue" : "Soft Blue Light"
        let input = try AANestedGroupsGalleryTests.input(theme)
        _ = ThemeScope.app.store.apply(input)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec(theme), input: input, animated: false)
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let section = MachineSectionView(actions: MachineSectionView.Actions(newWorkspace: { _ in }, addMachine: {}))
        section.update([MachineSectionRow(id: "local", name: "This Mac", isConnected: true, isLocal: true)] + MachineSectionRow.fixtures,
                       style: style)
        section.frame = root.bounds
        root.addSubview(section)
        window.orderFrontRegardless()
        // The first row shows New Workspace as it does under the pointer.
        section.rowViews["local"]?.setPointerInside(true)
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = try #require(rep.cgImage)
        window.close()
        return image
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "machines-section-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [[CGImage]] = []
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            var line: [CGImage] = []
            for style in MachineSectionStyle.allCases {
                let image = try Self.render(style, appearance: appearance)
                line.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(style.rawValue)-\(name).png"))
            }
            images.append(line)
        }
        let w = images[0][0].width, h = images[0][0].height, gap = 16
        let columns = images[0].count, lines = images.count
        let ctx = try #require(CGContext(data: nil, width: columns * w + (columns - 1) * gap, height: lines * h + (lines - 1) * gap,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (line, row) in images.enumerated() {
            for (column, image) in row.enumerated() {
                ctx.draw(image, in: CGRect(x: column * (w + gap), y: (lines - 1 - line) * (h + gap), width: w, height: h))
            }
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(ctx.makeImage()), to: out.appending(path: "all.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "machines-section-gallery.tar", "machines-section-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
