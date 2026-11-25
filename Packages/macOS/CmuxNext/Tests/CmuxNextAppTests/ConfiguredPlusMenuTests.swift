import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.closesItsWindows, .serialized) struct ConfiguredPlusMenuTests {
    @Test func orderedActionsKeepTheirTargetsAndExplicitLocalDestination() throws {
        let registry = ActionRegistry.standard()
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"tabs":{"plusMenu":["host","machineWorkspace","localWorkspace","terminal"]}}"#.utf8))
        let target = ActionTargetRef(kind: .pane, id: "remote-pane")
        let menu = try #require(registry.makeConfiguredPlusMenu(root: root, target: target, machineID: "remote", localMachineID: "local"))
        let runs = menu.items.compactMap { ActionRegistry.menuRun(of: $0) }
        #expect(runs.map(\.id.rawValue) == ["remote.connect", "workspace.newOnMachine", "workspace.newOnMachine", "newSurface"])
        try #require(runs.count == 4)
        #expect(runs[0].target == target)
        #expect(runs[0].arguments.isEmpty, "the existing host picker asks for the destination")
        #expect(runs[1].target == nil)
        #expect(runs[1].arguments.isEmpty, "New Workspace on Machine… asks for the machine")
        #expect(runs[2].target == nil)
        #expect(runs[2].arguments["machine"] == .string("local"))
        #expect(runs[3].target == target)
        #expect(menu.items.compactMap { ($0.representedObject as? ActionMenuPayload)?.targetMachineID } == ["remote", "remote", "local", "remote"])
        #expect(registry.makeConfiguredPlusMenu(root: .null, target: target, machineID: "remote", localMachineID: "local") == nil)
    }

    @Test func primaryMouseAndAccessibilityUseConfiguredMenuWhileOtherEntrypointsKeepTheirBehavior() throws {
        _ = NSApplication.shared
        let strip = TabStripView(model: TabStripModel(tabs: [TabItem(id: TabID("one"), title: "One")], selectedID: TabID("one")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = strip
        defer { window.closeAfterTest() }
        strip.showsNewTabMenuButton = true
        strip.layoutSubtreeIfNeeded()
        let primary = NSMenu(), chooser = NSMenu()
        primary.addItem(withTitle: "Primary", action: nil, keyEquivalent: "")
        chooser.addItem(withTitle: "Chooser", action: nil, keyEquivalent: "")
        strip.primaryNewTabMenuProvider = { primary }
        strip.contextMenuProvider = { _ in chooser }
        var shown: [NSMenu] = [], intents: [TabStripIntent] = []
        strip.presentNewTabMenu = { menu, _, _ in shown.append(menu) }
        strip.model.intentHandler = { intents.append($0) }
        let point = strip.newTabButton.convert(NSPoint(x: strip.newTabButton.bounds.midX, y: strip.newTabButton.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        strip.mouseDown(with: try event(.leftMouseDown))
        strip.mouseUp(with: try event(.leftMouseUp))
        #expect(shown == [primary])
        #expect(intents.isEmpty)
        #expect(strip.newTabButton.accessibilityPerformPress())
        #expect(shown == [primary, primary])
        strip.showNewTabMenu()
        #expect(strip.newTabMenuButton.accessibilityPerformPress())
        #expect(shown == [primary, primary, chooser, chooser])
        strip.mouseDown(with: try event(.leftMouseDown, .option))
        strip.mouseUp(with: try event(.leftMouseUp, .option))
        #expect(intents == [.newTab(after: nil, sameKind: true)])
        strip.primaryNewTabMenuProvider = { nil }
        #expect(strip.newTabButton.accessibilityPerformPress())
        #expect(intents.last == .newTab(after: nil, sameKind: false))
    }
}
