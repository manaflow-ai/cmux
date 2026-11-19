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

    /// Mounts `source` and hands `body` the runtime plus a reader that collects
    /// the help text of every element in the host's accessibility tree, which
    /// is where SwiftUI reports a `.help` tooltip.
    private func withTooltips<T>(
        of source: String,
        _ body: (SidebarJSRuntime, () throws -> [String]) throws -> T
    ) throws -> T {
        // SwiftUI builds no accessibility elements until an assistive client
        // turns the application's AX hierarchy on. An in-process test has no
        // such client, so it sets and restores that state itself.
        let app = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        try #require(app.accessibilityIsAttributeSettable(enhancedUI))
        let previousEnhancedUI = (app.accessibilityAttributeValue(enhancedUI) as? NSNumber)?.boolValue ?? false
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(previousEnhancedUI, forAttribute: enhancedUI) }

        let runtime = SidebarJSRuntime()
        runtime.start(source: source)
        #expect(runtime.errorMessage == nil)
        let rootId = try #require(runtime.store.rootId)
        let host = NSHostingView(
            rootView: SceneNodeView(nodeId: rootId)
                .environment(\.sceneStore, runtime.store)
                .environment(\.accessibilityEnabled, true)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        // SwiftUI's nodes are proxies that need not be `NSAccessibilityElement`
        // subclasses, so read them through the selectors AppKit itself calls.
        func value(_ getter: String, of object: NSObject) -> Any? {
            let selector = NSSelectorFromString(getter)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        return try body(runtime) {
            host.layoutSubtreeIfNeeded()
            var texts: [String] = []
            var elements = 0
            var pending: [Any] = host.accessibilityChildren() ?? []
            while let next = pending.popLast(), elements < 200 {
                guard let element = next as AnyObject as? NSObject else { continue }
                elements += 1
                if let help = value("accessibilityHelp", of: element) as? String, !help.isEmpty {
                    texts.append(help)
                }
                pending.append(contentsOf: value("accessibilityChildren", of: element) as? [Any] ?? [])
            }
            // A walk that reached no element proves nothing about tooltips.
            try #require(elements > 0, "SwiftUI exposed no accessibility elements for the mounted scene")
            return texts
        }
    }

    private func accessibilityHelpTexts(_ source: String) throws -> [String] {
        try withTooltips(of: source) { _, tooltips in try tooltips() }
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

    /// https://github.com/manaflow-ai/cmux/issues/45482: `.help("tip")` is a
    /// documented chainable prop, but the JS renderer dropped it, so hovering
    /// the node showed no tooltip.
    @Test func helpSetsTheTooltipText() throws {
        let plain = try accessibilityHelpTexts("sidebar(() => Text(\"56%\"))")
        let tipped = try accessibilityHelpTexts("sidebar(() => Text(\"56%\").help(\"Weekly: 56% left\"))")
        #expect(plain.isEmpty)
        #expect(tipped == ["Weekly: 56% left"])
    }

    /// The tooltip belongs to the node it was chained on: a sibling without
    /// `.help` gets none, and a stack can carry one for the whole row.
    @Test func helpStaysOnTheNodeItWasChainedOn() throws {
        let siblings = try accessibilityHelpTexts("""
        sidebar(() => VStack([Text("Claude").help("Weekly limit"), Text("Codex")]))
        """)
        #expect(siblings == ["Weekly limit"])

        let row = try accessibilityHelpTexts("""
        sidebar(() => HStack([Image("gauge"), Spacer()]).help("Usage"))
        """)
        #expect(row.contains("Usage"))
    }

    /// A function-valued `help` is a live binding like any other prop: the
    /// tooltip follows the data, and an empty string shows none.
    @Test func helpFollowsALiveBinding() throws {
        try withTooltips(of: "sidebar(() => Text(\"Claude\").help(() => data.tip() ?? \"\"))") { runtime, tooltips in
            let unset = try tooltips()
            #expect(unset.isEmpty)
            runtime.updateData(key: "tip", value: .string("56% left"))
            let first = try tooltips()
            #expect(first == ["56% left"])
            runtime.updateData(key: "tip", value: .string("12% left"))
            let second = try tooltips()
            #expect(second == ["12% left"])
            runtime.updateData(key: "tip", value: .string(""))
            let cleared = try tooltips()
            #expect(cleared.isEmpty)
        }
    }
}
