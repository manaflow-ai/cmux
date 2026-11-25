import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing
import UniformTypeIdentifiers

/// The before/after picture of the misaligned "Perf" group (user 2026-10-21, screenshot 10.07.20 PM),
/// stacked in `.build/sidebar-group-alignment.png` (a fleet step returns it with `--artifact`): before,
/// the data a reorder drop under "Panes & layout"'s last row made (Perf its subgroup, one gutter in);
/// after, the same drop with the fix (Perf stays a top-level group, aligned with the others). It checks
/// only that each drew; `SidebarGroupAlignmentTests` checks the offsets.
@Suite(.closesItsWindows)
@MainActor struct SidebarGroupAlignmentCaptureTests {
    private static let size = NSSize(width: 300, height: 340)

    private func render(nested: Bool) throws -> CGImage? {
        _ = NSApplication.shared
        func group(_ id: String, _ name: String, _ color: GroupColor, _ members: [String], parent: String? = nil) -> SidebarNode {
            var made = SidebarGroup(id: GroupID(id), name: name, color: color,
                                    workspaces: members.enumerated().map { SidebarWorkspace(id: WorkspaceID("\(id)-\($0.offset)"), title: $0.element) })
            made.parent = parent.map(GroupID.init)
            made.depth = parent == nil ? 0 : 1
            return .group(made)
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [
            group("g_panes", "Panes & layout", .cyan, ["Pane tabs", "Split spring"]),
            group("g_perf", "Perf", .yellow, ["Chief · tab switch fast", "Chief · Settings perf", "Workspace and tab switch perf regression"],
                  parent: nested ? "g_panes" : nil),
            group("g_nightly", "Nightly & CI", .red, ["Nightly unblock", "Nightly on minis"]),
        ])])
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let root = NSView(frame: NSRect(origin: .zero, size: Self.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        root.layoutSubtreeIfNeeded()
        CATransaction.flush()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep.cgImage
    }

    @Test func beforeAndAfter() throws {
        let before = try #require(try render(nested: true))
        let after = try #require(try render(nested: false))
        let gap = 16
        let width = before.width + gap + after.width, height = max(before.height, after.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(before, in: CGRect(x: 0, y: height - before.height, width: before.width, height: before.height))
        context.draw(after, in: CGRect(x: before.width + gap, y: height - after.height, width: after.width, height: after.height))
        let image = try #require(context.makeImage())
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".build/sidebar-group-alignment.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
