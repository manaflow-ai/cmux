import AppKit
import CmuxNextDesign
import CmuxTheme
@testable import CmuxNextSidebar
import Testing

/// Scratch preview (not for merge): renders the real SidebarView's layer tree with a named and an
/// unnamed group to PNG and prints it base64 in the log, for the PR's before/after images.
@MainActor @Suite(.serialized) struct SidebarGroupLinePreview {
    static func sidebar(joined: Bool) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func ws(_ id: String, _ title: String) -> SidebarWorkspace { SidebarWorkspace(id: WorkspaceID(id), title: title) }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("w0", "notes")),
                .group(SidebarGroup(id: GroupID("g1"), name: "Backend", color: .green, workspaces: [ws("w1", "api server"), ws("w2", "migrations"), ws("w3", "worker")])),
                .group(SidebarGroup(id: GroupID("g2"), name: "", color: .blue, workspaces: [ws("w4", "sidebar"), ws("w5", "build")])),
                .group(SidebarGroup(id: GroupID("g3"), name: "Design", color: .pink, workspaces: [ws("w6", "tokens")])),
            ]),
        ])
        let design = DesignSettings()
        design.sidebarSections.groupLineJoinsHeader = joined
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 420)
        return sidebar
    }

    static func render(_ name: String, joined: Bool, dark: Bool) throws {
        let sidebar = Self.sidebar(joined: joined)
        let scope = try #require(GroupPaletteDefaultTests.themes().first { $0.0 == (dark ? "dark" : "light") }?.1)
        scope.root(sidebar)
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = NSView(frame: sidebar.frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = scope.tokens.sidebarBackground.withAlpha(1).nsColor.cgColor
        root.addSubview(sidebar)
        window.contentView = root
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        root.layoutSubtreeIfNeeded()
        for view in sidebar.list.rowViews.values { view.layoutSubtreeIfNeeded(); view.updateLayer() }
        root.displayIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let scale: CGFloat = 2
        let size = root.bounds.size
        let ctx = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: scale, y: scale)
        if root.layer?.isGeometryFlipped == false && !root.isFlipped { } else { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
        try #require(root.layer).render(in: ctx)
        let image = try #require(ctx.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        print("PREVIEWPNG \(name) \(png.base64EncodedString())")
        window.orderOut(nil)
    }

    @Test func renderPreviews() throws {
        for dark in [true, false] {
            try Self.render("head-cut-\(dark ? "dark" : "light")", joined: false, dark: dark)
            try Self.render("head-joined-\(dark ? "dark" : "light")", joined: true, dark: dark)
        }
    }
}
