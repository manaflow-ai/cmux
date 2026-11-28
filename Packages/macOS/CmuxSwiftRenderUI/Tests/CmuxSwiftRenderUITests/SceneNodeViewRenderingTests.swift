import AppKit
import CmuxSwiftRender
@testable import CmuxSwiftRenderUI
import SwiftUI
import Testing

/// Opens a scene row's context menu through the real host view, the same
/// AppKit path a right-click takes, so menu items the host fails to render
/// show up as missing entries.
@MainActor
@Suite(.serialized)
struct SceneNodeViewRenderingTests {
    /// Runtime actions dispatch asynchronously after the event. Wait for the
    /// captured action, with a deadline so a broken dispatch still fails.
    private func waitForAction(
        _ expected: [ActionCommand],
        captured: @escaping @MainActor () -> [ActionCommand]
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while captured() != expected, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
    }

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

    /// A keyed row keeps its tap action after attaching a context menu. This
    /// is the same modifier combination used by the bundled workspace rows.
    @Test func forEachRowPreservesTapActionWithContextMenu() async throws {
        let runtime = SidebarJSRuntime()
        var captured: [ActionCommand] = []
        runtime.dispatch = SidebarActionDispatch { action in
            captured.append(contentsOf: action.commands)
        }
        runtime.start(source: """
        sidebar(() => VStack([
          ForEach(
            { items: () => data.items() ?? [], key: (item) => item.id },
            (item) => HStack([
              Text(() => item().title),
              Spacer(),
            ])
              .paddingVertical(6)
              .frame({ maxWidth: "infinity" })
              .onTap(() => cmux("workspace.select", { workspace_id: item().id }))
              .contextMenu([Button("Pin", () => {})])
          ),
        ]))
        """)
        #expect(runtime.errorMessage == nil)
        runtime.updateData(key: "items", value: .array([
            .object(["id": .string("w1"), "title": .string("Workspace")]),
        ]))
        let rootId = try #require(runtime.store.rootId)
        let listId = try #require(runtime.store.node(rootId)?.children.first)
        let rowId = try #require(runtime.store.node(listId)?.children.first)
        #expect(runtime.store.node(rowId)?.bool("tappable") == true)
        let menuId = try #require(runtime.store.node(rowId)?.children.first {
            runtime.store.node($0)?.type == "contextMenu"
        })
        #expect(runtime.store.node(menuId)?.type == "contextMenu")
        runtime.dispatchEvent(nodeId: rowId, event: "tap")
        let expected: [ActionCommand] = [
            .cmux(method: "workspace.select", params: ["workspace_id": "w1"]),
        ]
        await waitForAction(expected, captured: { captured })
        #expect(captured == expected)
    }
}
