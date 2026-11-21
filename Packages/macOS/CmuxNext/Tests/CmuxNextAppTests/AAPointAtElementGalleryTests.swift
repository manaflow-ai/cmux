import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Point at Element over native UI (ask-5077a4ec48): the outline and its chip on a sidebar workspace row, a tab and a
/// pane, in each of the three looks (`outline`, `filled`, `brackets`), dark and light. The element and its frame come
/// from the real resolver (`UIPointerNativeElement.elements`), the drawing from the real `UIPointerHighlightView`.
/// Written under `point-at-element-gallery/` as `<look>-<dark|light>.png` and `sheet.png` (a row per look), bundled
/// to `point-at-element-gallery.tar` for `cmux-ci run --artifact`.
@MainActor @Suite(.serialized, .closesItsWindows) struct AAPointAtElementGalleryTests {
    static func shot(look: UIPointerHighlightView.Look, dark: Bool) throws -> CGImage {
        let (window, row, tab, pane) = InspectElementNativeCostTests.nativeWindow()
        defer { window.close() }
        let root = try #require(window.contentView)
        try AAPinnedNoCloseGalleryTests.theme(root, window, dark: dark)
        let fill = NSView(frame: pane.bounds)
        fill.wantsLayer = true
        fill.layer?.backgroundColor = root.performWithTheme { Palette.sidebarBackground.withAlphaComponent(1) }.cgColor
        pane.addSubview(fill, positioned: .below, relativeTo: nil)
        let label = NSTextField(labelWithString: "notes.md")
        label.frame = tab.insetBy(dx: 12, dy: 6)
        root.addSubview(label)
        for point in [NSPoint(x: row.frame.midX, y: row.frame.midY), NSPoint(x: tab.midX, y: tab.midY),
                      NSPoint(x: pane.frame.midX, y: pane.frame.midY)] {
            let element = try #require(UIPointerNativeElement.elements(at: point, in: window).first)
            var rect = UIPointerHighlightView.frame(around: element.frame, in: window)
            if element.kind == .pane { rect = rect.intersection(root.bounds) }
            let outline = UIPointerHighlightView(frame: rect)
            outline.show(element, look: look, outlineIn: rect, around: element.frame)
            outline.frame = rect
            root.addSubview(outline)
        }
        return try AAPinnedNoCloseGalleryTests.crop(root, root.bounds)
    }

    @Test func renderGallery() throws {
        let root = AANestedGroupsGalleryTests.packageRoot
        let out = root.appending(path: "point-at-element-gallery")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var sheet: [[CGImage]] = []
        for look in UIPointerHighlightView.Look.allCases {
            var row: [CGImage] = []
            for dark in [true, false] {
                let image = try Self.shot(look: look, dark: dark)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(look.rawValue)-\(dark ? "dark" : "light").png"))
                row.append(image)
            }
            sheet.append(row)
        }
        try AAGroupHeaderDensityGalleryTests.write(try AAFaviconStyleGalleryTests.sheet(sheet), to: out.appending(path: "sheet.png"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = root
        tar.arguments = ["cf", "point-at-element-gallery.tar", "point-at-element-gallery"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
    }
}
