import AppKit
@testable import CmuxNextActions
import Testing

/// A split divider's right-click menu (Leo 2026-11-07): Insert New ▸ Terminal, Browser, Agent Chat, New Tab
/// Page, then Hide Divider or Show Divider. Every row runs on the right-clicked split, so the same actions run
/// from the palette and the CLI (`cmux divider insert|hide|show`).
@MainActor @Suite struct DividerMenuTests {
    final class Recorder {
        let registry = ActionRegistry.standard()
        var runs: [(ActionID, ActionInvocation)] = []
        var hidden = false

        init() {
            registry.context = ActionContext(rawValue: .max)
            for id: ActionID in ["divider.insertNew", "divider.hide", "divider.show"] {
                registry.bind(id, invoke: { [unowned self] in runs.append((id, $0)) })
            }
            ActionTargetVisibility.hide("divider.hide", in: registry) { [unowned self] _ in hidden }
            ActionTargetVisibility.hide("divider.show", in: registry) { [unowned self] _ in !hidden }
        }

        func menu() -> NSMenu {
            registry.makeContextMenu(for: .divider, target: ActionTargetRef(kind: .workspace, id: "w1"),
                                     arguments: ["split": .string("split:7")], customize: false)
        }
    }

    static func run(_ item: NSMenuItem) { _ = (item.target as? NSObject)?.perform(item.action, with: item) }

    @Test func insertNewOffersEveryKindAndRunsOnTheRightClickedSplit() throws {
        let recorder = Recorder()
        let menu = recorder.menu()
        let insert = try #require(menu.items.first { $0.submenu != nil })
        #expect(insert.title == "Insert New")
        let kinds = try #require(insert.submenu).items
        #expect(kinds.map(\.title) == ["Terminal", "Browser", "Agent Chat", "New Tab Page"])
        Self.run(kinds[2])
        let run = try #require(recorder.runs.last)
        #expect(run.0 == "divider.insertNew")
        #expect(run.1["kind"]?.stringValue == "agentChat")
        #expect(run.1["split"]?.stringValue == "split:7", "the choice lost the divider it was opened on")
        #expect(run.1.target == ActionTargetRef(kind: .workspace, id: "w1"))
    }

    @Test func aDrawnDividerOffersHideAndAHiddenOneShow() throws {
        let recorder = Recorder()
        let titles = { recorder.menu().items.filter { !$0.isSeparatorItem && $0.submenu == nil }.map(\.title) }
        #expect(titles() == ["Hide Divider"])
        recorder.hidden = true
        #expect(titles() == ["Show Divider"])
        let show = try #require(recorder.menu().items.first { $0.title == "Show Divider" })
        Self.run(show)
        #expect(recorder.runs.last?.0 == "divider.show")
        #expect(recorder.runs.last?.1["split"]?.stringValue == "split:7")
    }

    @Test func theRowsAreScriptableAndSearchable() throws {
        for (id, cli) in [("divider.insertNew", "divider insert"), ("divider.hide", "divider hide"), ("divider.show", "divider show")] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id == ActionID(rawValue: id) })
            #expect(descriptor.cliName == cli)
            #expect(descriptor.surfaces.contains(.palette))
        }
    }
}
