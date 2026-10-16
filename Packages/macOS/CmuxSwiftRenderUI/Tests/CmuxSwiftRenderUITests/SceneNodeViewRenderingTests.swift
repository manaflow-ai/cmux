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
    /// Synchronous by design: `RunLoop.run(until:)` is unavailable directly
    /// from an async test, but is needed to deliver the posted AppKit events.
    private func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Sends a left click through AppKit so SwiftUI's native gesture routing
    /// is exercised instead of calling the scene event sink directly.
    private func postLeftClick(at point: NSPoint, in host: NSView, window: NSWindow) async {
        for (eventNumber, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber + 1,
                clickCount: 1,
                pressure: 1
            ) else { continue }
            if type == .leftMouseDown {
                host.mouseDown(with: event)
            } else {
                host.mouseUp(with: event)
            }
        }
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 10_000_000) }
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

    /// A keyed row keeps its native tap after attaching a context menu. This
    /// is the same modifier combination used by the bundled workspace rows.
    @Test func forEachRowTapDispatchesThroughNativeHost() async throws {
        _ = NSApplication.shared
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
        var sceneEvents: [(nodeId: String, event: String)] = []
        let sink = SceneEventSink { nodeId, event, payload in
            _ = payload
            sceneEvents.append((nodeId, event))
        }
        let host = NSHostingView(
            rootView: SceneNodeView(nodeId: rootId)
                .environment(\.sceneStore, runtime.store)
                .environment(\.sceneEventSink, sink)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        #expect(runtime.store.node(rowId)?.bool("tappable") == true)
        await postLeftClick(at: NSPoint(x: 20, y: 14), in: host, window: window)

        #expect(sceneEvents.count == 1)
        #expect(sceneEvents.first?.nodeId == rowId)
        #expect(sceneEvents.first?.event == "tap")
        runtime.dispatchEvent(nodeId: rowId, event: "tap")
        #expect(captured == [
            .cmux(method: "workspace.select", params: ["workspace_id": "w1"]),
        ])
    }
}
