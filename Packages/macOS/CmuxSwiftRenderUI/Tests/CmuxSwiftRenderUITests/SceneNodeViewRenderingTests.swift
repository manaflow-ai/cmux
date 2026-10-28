import AppKit
@testable import CmuxSwiftRenderUI
import SwiftUI
import Testing

/// Opens a scene row's context menu through the real host view, the same
/// AppKit path a right-click takes, so menu items the host fails to render
/// show up as missing entries.
@MainActor
struct SceneNodeViewRenderingTests {
    private func contextMenu(ofRoot runtime: SidebarJSRuntime) throws -> NSMenu {
        let rootId = try #require(runtime.store.rootId)
        let host = NSHostingView(
            rootView: SceneNodeView(nodeId: rootId)
                .environment(\.sceneStore, runtime.store)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let center = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: host.convert(center, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        return try #require(host.menu(for: event))
    }

    /// Mounts `source` and asks SwiftUI how big the root wants to be when
    /// offered `proposal` - the same negotiation an `HStack` runs with a
    /// badge or button squeezed beside stretching text.
    private func renderedSize(_ source: String, proposal: CGSize) throws -> CGSize {
        let runtime = SidebarJSRuntime()
        runtime.start(source: source)
        #expect(runtime.errorMessage == nil)
        let rootId = try #require(runtime.store.rootId)
        let host = NSHostingController(
            rootView: SceneNodeView(nodeId: rootId)
                .environment(\.sceneStore, runtime.store)
        )
        return host.sizeThatFits(in: proposal)
    }

    @Test func jsonBundledImageHonorsSize() throws {
        let name = "AgentIcons/JSONSizingRegression"
        let image = NSImage(size: NSSize(width: 14, height: 14))
        #expect(image.setName(name))
        defer { image.setName(nil) }
        var node = DSLNode(type: .image)
        node.systemName = name
        node.size = 32
        let host = NSHostingController(rootView: DSLSidebarRenderer(node: node, onAction: { _ in }))
        let size = host.sizeThatFits(in: CGSize(width: 100, height: 100))
        #expect(size.width == 32)
        #expect(size.height == 32)
    }

    private func renderedImage(_ source: String) throws -> Data {
        let runtime = SidebarJSRuntime()
        #expect(runtime.start(source: source))
        let rootId = try #require(runtime.store.rootId)
        let renderer = ImageRenderer(content:
            SceneNodeView(nodeId: rootId)
                .environment(\.sceneStore, runtime.store)
                .foregroundStyle(.black)
                .frame(width: 40, height: 40)
        )
        let image = try #require(renderer.cgImage)
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    @Test func assetSymbolFallbackMatchesNameForm() throws {
        let reference = try renderedImage("sidebar(() => Image(\"person.fill\").size(20))")
        let fallback = try renderedImage("sidebar(() => Image({ asset: () => \"person.fill\" }).size(20))")
        #expect(fallback == reference)
    }

    private let wideLabel = "A label much wider than forty points"

    @Test func fixedSizeKeepsNaturalWidthWhenSqueezed() throws {
        let narrow = CGSize(width: 40, height: 400)
        let squeezed = try renderedSize("sidebar(() => Text(\"\(wideLabel)\").lineLimit(1))", proposal: narrow)
        let fixed = try renderedSize("sidebar(() => Text(\"\(wideLabel)\").lineLimit(1).fixedSize())", proposal: narrow)
        #expect(squeezed.width <= 40)
        #expect(fixed.width > 40)
    }

    @Test func fixedSizeHonorsTheRequestedAxis() throws {
        // Wrapping text offered a short, narrow box: without fixedSize it
        // accepts both limits; each axis token keeps only its own axis natural.
        let box = CGSize(width: 40, height: 20)
        let horizontal = try renderedSize("sidebar(() => Text(\"\(wideLabel)\").fixedSize(\"horizontal\"))", proposal: box)
        let vertical = try renderedSize("sidebar(() => Text(\"\(wideLabel)\").fixedSize(\"vertical\"))", proposal: box)
        #expect(horizontal.width > 40)
        #expect(vertical.width <= 40)
        #expect(vertical.height > 20)
    }

    /// https://github.com/manaflow-ai/cmux/issues/14662: a `Menu` inside
    /// `.contextMenu` rendered nothing, so the submenu vanished from the
    /// context menu while its sibling buttons still showed.
    @Test func contextMenuSubmenuRenders() throws {
        let runtime = SidebarJSRuntime()
        runtime.start(source: """
        sidebar(() =>
          Text("row").contextMenu([
            Button("Open chat", () => {}),
            Divider(),
            Menu("Move to project", [Button("fun", () => {}), Button("Landing", () => {})]),
          ])
        )
        """)
        let menu = try contextMenu(ofRoot: runtime)

        #expect(menu.items.first?.title == "Open chat")
        #expect(menu.items.contains { $0.isSeparatorItem })
        let submenuItem = try #require(menu.items.first { $0.title == "Move to project" })
        let submenu = try #require(submenuItem.submenu)
        #expect(submenu.items.map(\.title) == ["fun", "Landing"])
    }
}
