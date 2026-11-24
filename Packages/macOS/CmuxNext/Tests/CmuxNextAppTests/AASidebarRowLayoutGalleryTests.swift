import AppKit
@testable import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// Three configurations through Settings, the pinned Rust reducer and the real
/// native sidebar. No fixture substitutes element switches for layout parsing.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AASidebarRowLayoutGalleryTests {
    struct Variant: Sendable {
        let name: String
        let json: String
    }

    static let variants = [
        Variant(name: "quiet", json: #"{"sidebar":{"workspaceRow":{"lines":[["icon","name","working"]]}}}"#),
        Variant(name: "by-kind", json: #"{"sidebar":{"workspaceRow":{"lines":[["name"]],"linesByKind":{"agent":[["name","working"],["agentStatus"]],"terminal":[["name","branch"],["directory"]]}}}}"#),
        Variant(name: "by-agent", json: #"{"sidebar":{"workspaceRow":{"lines":[["name"],["directory"]],"linesByAgent":{"codex":[["name","working"],["branch"],["log","pullRequest"]],"claude":[["name","branch"],["agentStatus"]]}}}}"#),
    ]

    private static func sections() -> [SidebarSection] {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        var codex = WorkspaceRowLayoutRenderingTests.workspace()
        codex.title = "Sidebar customization"
        codex.agentWorking = true
        codex.status = "Checking the layout"
        var claude = SidebarWorkspace(id: WorkspaceID("claude"), title: "Project notes", directory: "~/notes", branch: "draft",
                                      rowKind: .agent, kind: .harness, activity: .idle)
        claude.kindBrand = "claude"
        claude.status = "Ready for review"
        let terminal = SidebarWorkspace(id: WorkspaceID("terminal"), title: "Build logs", directory: "~/project", branch: "feature",
                                        rowKind: .terminal, kind: .terminal, activity: .idle)
        return [SidebarSection(kind: .machine(machine), nodes: [.workspace(codex), .workspace(claude), .workspace(terminal)])]
    }

    private static func render(_ variant: Variant, dark: Bool) throws -> CGImage {
        _ = NSApplication.shared
        let width: CGFloat = 320, height: CGFloat = 320
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
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
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let preferences = try WorkspaceRowLayoutRenderingTests.preferences(variant.json)
        let design = DesignSettings()
        var sections = design.sidebarSections
        sections.workspaceRow = preferences
        design.sidebarSections = sections
        let model = SidebarModel(sections: Self.sections())
        model.workspaceRow = preferences
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.list.reload(animated: false)
        root.layoutSubtreeIfNeeded()
        for view in AANestedGroupsGalleryTests.all(root) {
            view.layoutSubtreeIfNeeded()
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        CATransaction.flush()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    @Test func theGalleryConfigurationsProduceDistinctNativeContent() throws {
        let node = try #require(Self.sections().first?.nodes.first)
        guard case let .workspace(row) = node else { Issue.record("fixture begins with a workspace"); return }
        let contents = try Self.variants.map { WorkspaceRowContent(row, preferences: try WorkspaceRowLayoutRenderingTests.preferences($0.json)) }
        #expect(Set(contents).count == Self.variants.count)
        #expect(contents[0].detail == nil)
        #expect(contents[1].detail == "Checking the layout")
        #expect(contents[2].meta == "Tests passed · #123")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_TEST_REQUIRE_GUI"] == "1"))
    func renderGallery() throws {
        let out = AANestedGroupsGalleryTests.packageRoot.appending(path: "sidebar-row-layout-gallery")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var images: [CGImage] = []
        for dark in [true, false] {
            for variant in Self.variants {
                let image = try Self.render(variant, dark: dark)
                images.append(image)
                try AAGroupHeaderDensityGalleryTests.write(image, to: out.appending(path: "\(dark ? "dark" : "light")-\(variant.name).png"))
            }
        }
        let first = try #require(images.first)
        let width = first.width, height = first.height, gap = 16
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 3 * width + 2 * gap, height: 2 * height + gap,
                                             bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        for (index, image) in images.enumerated() {
            context.draw(image, in: CGRect(x: (index % 3) * (width + gap), y: (1 - index / 3) * (height + gap), width: width, height: height))
        }
        try AAGroupHeaderDensityGalleryTests.write(try #require(context.makeImage()), to: out.appending(path: "all.png"))
    }
}
