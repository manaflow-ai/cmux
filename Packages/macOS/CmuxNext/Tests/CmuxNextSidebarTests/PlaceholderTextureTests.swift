import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// A placeholder row's braille texture: the row keeps the live row height
/// at every interface size, and neither the row nor its texture is an
/// accessibility element.
@MainActor @Suite(.serialized) struct PlaceholderTextureTests {
    /// A live row above a connecting Cloud section's placeholders.
    func sections() -> [SidebarSection] {
        let live = SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "Local", kind: .local)),
                                  nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("w0"), title: "api-server"))])
        let cloud = MachineID("cloud-1")
        let placeholders = (0..<3).map {
            SidebarWorkspace(id: WorkspaceID("placeholder:cloud-1:\($0)"), machineID: cloud, title: "", rowState: .placeholder)
        }
        return [live, SidebarSection(kind: .machine(SidebarMachine(id: cloud, name: "Cloud", kind: .cloud, status: .connecting)),
                                     nodes: placeholders.map(SidebarNode.workspace))]
    }

    func makeSidebar() -> SidebarView {
        let view = SidebarView(model: SidebarModel(sections: sections()))
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        view.layoutSubtreeIfNeeded()
        view.list.reload(animated: false)
        return view
    }

    /// Compact and comfortable, at the default size and the smallest and
    /// largest interface sizes (`appearance.metrics.chromeFontSize`).
    nonisolated static let sizes: [(Density, CGFloat?)] = Density.allCases.flatMap { density -> [(Density, CGFloat?)] in
        [(density, nil), (density, CGFloat(10)), (density, CGFloat(16))]
    }

    @Test(arguments: sizes)
    func aPlaceholderRowIsExactlyTheLiveRowHeight(density: Density, interfaceSize: CGFloat?) throws {
        let settings = DesignSettings.shared
        let original = (settings.density, settings.overrides[.chromeFontSize])
        defer {
            settings.density = original.0
            settings.setOverride(.chromeFontSize, original.1)
        }
        settings.density = density
        settings.setOverride(.chromeFontSize, interfaceSize)
        let view = makeSidebar()
        let live = try #require(view.list.rowViews[.workspace(WorkspaceID("w0"))] as? WorkspaceRowView)
        let placeholder = try #require(view.list.rowViews[.workspace(WorkspaceID("placeholder:cloud-1:0"))] as? WorkspaceRowView)
        placeholder.layoutSubtreeIfNeeded()
        #expect(placeholder.isShowingPlaceholder)
        #expect(placeholder.frame.height == live.frame.height, "\(density) at \(interfaceSize.map { "\($0) pt" } ?? "default")")
        // The texture spans the row's height and never pushes past it.
        let texture = placeholder.placeholderTexture
        #expect(!texture.isHidden)
        #expect(texture.frame.minY >= 0 && texture.frame.height == placeholder.frame.height)
        #expect(texture.frame.width > 0)
    }

    @Test func thePlaceholderRowAndItsTextureAreNoAccessibilityElements() throws {
        let view = makeSidebar()
        let placeholder = try #require(view.list.rowViews[.workspace(WorkspaceID("placeholder:cloud-1:1"))] as? WorkspaceRowView)
        placeholder.layoutSubtreeIfNeeded()
        #expect(!placeholder.isAccessibilityElement())
        #expect(!placeholder.placeholderTexture.isAccessibilityElement())
        #expect(placeholder.placeholderTexture.hitTest(NSPoint(x: 1, y: 1)) == nil)
        // The live row stays one.
        let live = try #require(view.list.rowViews[.workspace(WorkspaceID("w0"))])
        #expect(live.isAccessibilityElement())
    }

    /// macOS ships a braille face, so the texture draws glyphs, in a font
    /// that really has the cell (never the LastResort box).
    @Test func theTextureDrawsBrailleWhenAFontHasIt() throws {
        let font = try #require(PlaceholderTextureView.brailleFont(inkHeight: 6))
        #expect(font.fontName != "LastResort")
        #expect(PlaceholderTextureView.brailleFont(inkHeight: 0) == nil)
    }
}
