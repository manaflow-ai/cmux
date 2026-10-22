import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
import UniformTypeIdentifiers

/// Scratch gallery capture (not landed): the collapsed group with its active member, then after
/// another workspace is selected, for an unpinned and a pinned group, into `.build/selected-row-rail.png`.
@MainActor @Suite(.serialized) struct SelectedRowRailCaptureTests {
    @Test func capture() throws {
        var grid: [[CGImage]] = []
        for pinned in [false, true] {
            let (sidebar, model, window) = SidebarCollapsedGroupMemberTests.sidebar(pinned: pinned)
            defer { window.close() }
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
            window.orderFrontRegardless()
            sidebar.renderNow()
            let first = try #require(SidebarSelectionLookTests.snapshot(window.contentView!))
            model.selectedItem = .workspace(SidebarCollapsedGroupMemberTests.looseID)
            sidebar.renderNow()
            sidebar.list.layer?.removeAllAnimations()
            for view in sidebar.list.subviews { view.layer?.removeAllAnimations() }
            let second = try #require(SidebarSelectionLookTests.snapshot(window.contentView!))
            grid.append([first, second])
        }
        let gap = 16
        let cellW = grid[0][0].width, cellH = min(grid[0][0].height, 360 * grid[0][0].height / 600)
        let width = cellW * 2 + gap, height = cellH * 2 + gap
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (r, row) in grid.enumerated() {
            for (c, image) in row.enumerated() {
                let crop = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: cellH)) ?? image
                ctx.draw(crop, in: CGRect(x: c * (cellW + gap), y: height - (r + 1) * cellH - r * gap, width: cellW, height: cellH))
            }
        }
        let image = try #require(ctx.makeImage())
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/selected-row-rail.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
