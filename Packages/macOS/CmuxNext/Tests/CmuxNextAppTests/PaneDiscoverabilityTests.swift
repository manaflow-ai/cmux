import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

@MainActor @Suite(.serialized) struct PaneDiscoverabilityTests {
    @Test func aPlainPressOpensTheTypeMenuBeforeMouseUp() throws {
        let model = TabStripModel(tabs: [TabItem(id: TabID("sample"), title: "Chat")], selectedID: TabID("sample"))
        var intents: [TabStripIntent] = []
        model.intentHandler = { intents.append($0) }
        let strip = TabStripView(model: model)
        strip.opensNewTabMenuOnPress = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = strip
        strip.frame = window.contentLayoutRect
        strip.layoutSubtreeIfNeeded()
        let menu = NSMenu()
        menu.addItem(withTitle: "Terminal", action: nil, keyEquivalent: "")
        strip.contextMenuProvider = { _ in menu }
        var presentations = 0
        strip.presentNewTabMenu = { actual, _, _ in
            #expect(actual === menu)
            presentations += 1
        }
        let button = strip.newTabButton
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        strip.mouseDown(with: down)
        #expect(presentations == 1)
        #expect(intents.isEmpty)
        #expect(!strip.pressedNewTab)
        #expect(button.showsChevron)
        #expect(button.accessibilityRole() == .popUpButton)
        _ = strip.endNewTabPress(at: strip.convert(point, from: nil))
        #expect(presentations == 1)
        #expect(intents.isEmpty, "releasing the menu must not also create the default tab")
        #expect(button.accessibilityPerformPress())
        #expect(presentations == 2, "VoiceOver opens the same type menu")
        #expect(button.accessibilityPerformShowMenu())
        #expect(presentations == 3)
    }

    @Test func optionClickStillCreatesTheSameKind() throws {
        let model = TabStripModel(tabs: [TabItem(id: TabID("sample"), title: "Chat")], selectedID: TabID("sample"))
        var intents: [TabStripIntent] = []
        model.intentHandler = { intents.append($0) }
        let strip = TabStripView(model: model)
        strip.opensNewTabMenuOnPress = true
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        strip.layoutSubtreeIfNeeded()
        let button = strip.newTabButton
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: strip)
        strip.pressedNewTab = true
        #expect(strip.endNewTabPress(at: point, modifiers: [.option]))
        #expect(intents == [.newTab(after: nil, sameKind: true)], "Option-click keeps the existing same-kind action")
    }

    @Test func creationButtonsStayVisibleForChatAndTargetTheirOwnPane() throws {
        let registry = ActionRegistry.standard()
        let pane = ActionTargetRef(kind: .pane, id: "sample-pane")
        var calls: [ActionInvocation] = []
        for action in PaneToolbar.creationActions { registry.bind(action, invoke: { calls.append($0) }) }
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil }, paneTarget: pane)
        toolbar.update(target: "sample-chat", kind: nil)
        #expect(toolbar.view.items.map(\.id) == ["newSurface", "openBrowser"])
        #expect(toolbar.view.buttons.count == 2)
        toolbar.view.frame = NSRect(origin: .zero, size: NSSize(width: toolbar.view.intrinsicContentSize.width, height: 36))
        toolbar.view.layoutSubtreeIfNeeded()
        #expect(toolbar.view.buttons[0].frame.maxX <= toolbar.view.buttons[1].frame.minX)
        for button in toolbar.view.buttons {
            #expect(button.alphaValue == 1)
            #expect(HoverReveal.owner(of: button) == nil)
        }
        for item in toolbar.view.items {
            #expect(item.alwaysVisible)
            #expect(item.shortcut == registry.shortcutDisplay(for: ActionID(rawValue: item.id)))
            toolbar.view.onPerform?(item.id)
        }
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.target == pane && $0.origin == .user })
        registry.bind("splitRight", invoke: { _ in })
        toolbar.update(target: "sample-terminal", kind: .terminal, pinned: ["splitRight"])
        #expect(toolbar.view.items.prefix(2).allSatisfy(\.alwaysVisible))
        #expect(toolbar.view.items.last?.id == "splitRight", "existing pinned controls remain available")
    }
}
