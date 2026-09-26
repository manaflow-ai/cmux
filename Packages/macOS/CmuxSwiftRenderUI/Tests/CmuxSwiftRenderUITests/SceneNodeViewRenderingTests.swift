import AppKit
@testable import CmuxSwiftRenderUI
import SwiftUI
import Testing

/// Renders scene nodes through the real host view so a node type the JS
/// runtime emits but the host has no case for (and silently draws as
/// nothing) shows up as a failure.
@MainActor
struct SceneNodeViewRenderingTests {
    private func renderedSize(of nodeId: String, in runtime: SidebarJSRuntime) -> NSSize {
        let host = NSHostingView(
            rootView: SceneNodeView(nodeId: nodeId)
                .environment(\.sceneStore, runtime.store)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
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
        let rootId = try #require(runtime.store.rootId)
        let root = try #require(runtime.store.node(rootId))
        let menuId = try #require(root.children.first)
        let menu = try #require(runtime.store.node(menuId))
        let buttonId = try #require(menu.children.first)
        let submenuId = try #require(menu.children.last)
        let submenu = try #require(runtime.store.node(submenuId))
        #expect(submenu.type == "menu")
        #expect(submenu.children.compactMap { runtime.store.node($0)?.type } == ["button", "button"])

        // The sibling button is the control: if it renders, the harness works.
        let buttonSize = renderedSize(of: buttonId, in: runtime)
        #expect(buttonSize.width > 0 && buttonSize.height > 0)

        let submenuSize = renderedSize(of: submenuId, in: runtime)
        #expect(submenuSize.width > 0 && submenuSize.height > 0)
    }
}
