import AppKit
@testable import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTestSupport
import Testing

/// A chat page asks its tab's state, and the answer lists the moves the chat offers: the rows of
/// the chat's right-click menu (`AgentPaneModel.offeredMoves`). For a tab the tree does not have (a
/// chat page that asks before its tab is there) a row's rule looked the tab up, and the App's
/// refusal observer logged "action refused: That tab is no longer open." though nobody ran an
/// action. A menu build asks questions: it refuses nothing.
@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentChatMenuForAGoneTabTests {
    /// Every action of `entries`, at any depth.
    private static func actions(_ entries: [ContextMenuEntry]) -> [ActionID] {
        entries.flatMap { entry -> [ActionID] in
            switch entry {
            case .action(let id), .choices(let id): [id]
            case .submenu(let id, let children): [id] + actions(children)
            case .folder(_, let children), .group(_, let children): actions(children)
            case .separator: []
            }
        }
    }

    private static func rows(_ items: [NSMenuItem]) -> Int {
        items.reduce(0) { $0 + ($1.isSeparatorItem ? 0 : 1) + rows($1.submenu?.items ?? []) }
    }

    @Test func theChatsMenuForATabTheTreeDoesNotHaveRefusesNothing() {
        let services = AgentChatRefusalReasonTests.services()
        let registry = services.registry
        // The App's own observer stays in the chain: what it hears, it logs.
        var heard: [String] = []
        let previous = registry.refusalObserver
        registry.refusalObserver = { reason, quiet in
            heard.append(reason)
            previous?(reason, quiet)
        }
        defer { registry.refusalObserver = previous }
        // Count each call of a row's rule (left out, reason, title, check mark) in one build.
        let entries = registry.contextMenuEntries(for: .agentChat)
        var calls = 0
        for id in Set(Self.actions(entries)) {
            guard var action = registry.action(for: id) else { continue }
            if let rule = action.targetHidden { action.targetHidden = { calls += 1; return rule($0) } }
            if let rule = action.targetUnavailableReason { action.targetUnavailableReason = { calls += 1; return rule($0) } }
            if let rule = action.targetTitle { action.targetTitle = { calls += 1; return rule($0) } }
            if let rule = action.targetState { action.targetState = { calls += 1; return rule($0) } }
            registry.register(action)
        }
        let target = ActionTargetRef(kind: .tab, id: "a-tab-the-tree-does-not-have")
        let items = registry.contextMenuItems(for: .agentChat, target: target, entries: entries)
        print("agent-chat-menu: one build = \(Self.rows(items)) rows of \(Set(Self.actions(entries)).count) actions, \(calls) rule calls, \(heard.count) refusals \(heard)")
        #expect(!items.isEmpty, "the chat's menu has no row")
        #expect(calls > 0, "the build asked no rule")
        #expect(heard.isEmpty, "a menu build refused: \(heard)")
    }
}
