import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextSettings
import Testing

/// The Customize Inspector (hold Option over the window) and the right-click Customize… rows read
/// one Rust element map (cmux-action-catalog `customize_elements`); Leo, 2026-11-14: "the ergonomics
/// need to be real good like just ultra braindead".
@MainActor
struct CustomizeInspectorTests {
    @Test func everyElementOfTheMapIsAnsweredByAViewOfTheWindow() {
        let ids = Set(CustomizeElement.all.map(\.id))
        #expect(!ids.isEmpty, "the catalog has no customize_elements")
        #expect(ids == CustomizeElementHit.answeredIDs)
        for element in CustomizeElement.all {
            #expect(!element.settings.isEmpty, "\(element.id)")
            #expect(!element.tokens.isEmpty, "\(element.id)")
            #expect(element.title != element.id, "\(element.id) has no title")
        }
    }

    @Test func theInnermostElementUnderThePointWins() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let content = try #require(window.contentView)
        let pane = NSView(frame: NSRect(x: 100, y: 0, width: 300, height: 260))
        pane.identifier = CustomizeElementHit.identifier("pane")
        let strip = Pointing(frame: NSRect(x: 0, y: 230, width: 300, height: 30))
        pane.addSubview(strip)
        content.addSubview(pane)
        let inPane = try #require(CustomizeElementHit.resolve(in: window, at: NSPoint(x: 150, y: 50)))
        #expect(inPane.id == "pane")
        #expect(inPane.frame == pane.convert(pane.bounds, to: nil))
        let onTab = try #require(CustomizeElementHit.resolve(in: window, at: NSPoint(x: 120, y: 240)))
        #expect(onTab.id == "tab")
        #expect(onTab.frame == strip.convert(NSRect(x: 0, y: 0, width: 80, height: 30), to: nil))
        let onBar = try #require(CustomizeElementHit.resolve(in: window, at: NSPoint(x: 300, y: 240)))
        #expect(onBar.id == "tabBar")
        #expect(CustomizeElementHit.resolve(in: window, at: NSPoint(x: 50, y: 50)) == nil)
    }

    @Test func optionAloneHoldsTheInspector() {
        #expect(CustomizeInspector.holdsInspector(.option))
        #expect(CustomizeInspector.holdsInspector([.option, .capsLock]))
        #expect(!CustomizeInspector.holdsInspector([.option, .command]))
        #expect(!CustomizeInspector.holdsInspector([.option, .shift]))
        #expect(!CustomizeInspector.holdsInspector([]))
    }

    @Test func aReleaseOutsideTheCardEndsTheInspector() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let inspector = CustomizeInspector(window: window, registry: ActionRegistry())
        inspector.show(try #require(CustomizeElement.named("pane")), frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        #expect(inspector.shown?.element.id == "pane")
        inspector.holdChanged([.option, .command])
        #expect(inspector.shown == nil, "a chord is not the inspector")
        inspector.show(try #require(CustomizeElement.named("pane")), frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        inspector.holdChanged(nil)
        #expect(inspector.shown == nil)
    }

    @Test func theCardShowsTheElementAndItsButtonsRunItsActions() throws {
        let element = try #require(CustomizeElement.named("tabBar"))
        let card = CustomizeInspectorCardView()
        var changed: [String] = [], reset: [String] = []
        card.show(element, change: { changed.append(element.id) }, reset: { reset.append(element.id) })
        #expect(card.shownText.first == element.title)
        #expect(card.shownText[1].contains(element.settings[0]))
        #expect(card.shownText[2].contains(element.tokens[0]))
        card.changeControl.performClick(nil)
        card.resetControl.performClick(nil)
        #expect(changed == ["tabBar"])
        #expect(reset == ["tabBar"])
    }

    @Test func theButtonsRunTheRegisteredActionsWithTheElement() throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var opened: [ActionInvocation] = []
        #expect(registry.bindAgentPane { opened.append($0) })
        let element = try #require(CustomizeElement.named("chatComposer"))
        CustomizeInspector.actions(registry).change(element)
        let invocation = try #require(opened.first)
        #expect(invocation["element"]?.stringValue == "chatComposer")
        #expect(AgentHandlers.seed(for: invocation).draft == "/customize \(element.title): ")
    }

    @Test func theWindowCustomizeSurfacesAreOneDefaultOffSettingOnEverySurface() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.customizeFromTheAppPath))
        #expect(CmuxConfigSnapshot.customizeFromTheAppDefault == false)
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains(descriptor.id))
        #expect(CmuxConfigSnapshot.empty.customizeFromTheApp == false)
    }

    @Test func rightClickCustomizeIsHiddenUntilTheSettingIsOn() {
        var on = false
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        #expect(registry.bindAgentPane(customizeRows: { on }) { _ in })
        let id = ActionID(rawValue: CustomizeElement.openActionID)
        #expect(ActionRegistry.locate(id, in: registry.makeContextMenu(for: .tabStrip)) == nil)
        on = true
        #expect(ActionRegistry.locate(id, in: registry.makeContextMenu(for: .tabStrip)) != nil)
    }

    @Test func aRightClickCustomizeRowNamesItsMenusElement() throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        var opened: [ActionInvocation] = []
        #expect(registry.bindAgentPane(customizeRows: { true }) { opened.append($0) })
        let menu = registry.makeContextMenu(for: .tabStrip)
        let found = try #require(ActionRegistry.locate(ActionID(rawValue: CustomizeElement.openActionID), in: menu))
        let run = try #require(ActionRegistry.menuRun(of: found.menu.items[found.index]))
        #expect(run.arguments["element"]?.stringValue == "tabBar")
    }

    @Test func noElementKeepsThePlainDraft() {
        #expect(AgentPaneSeed.customizeDraft(for: nil) == "/customize ")
    }
}

/// A strip with one tab at its leading 80 points, the way `TabStripView` answers.
@MainActor
private final class Pointing: NSView, CustomizeElementPointing {
    func customizeElement(at point: NSPoint) -> CustomizeElementHit? {
        guard bounds.contains(point) else { return nil }
        return point.x < 80 ? CustomizeElementHit(id: "tab", frame: NSRect(x: 0, y: 0, width: 80, height: 30))
            : CustomizeElementHit(id: "tabBar", frame: bounds)
    }
}
