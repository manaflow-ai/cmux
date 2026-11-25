#if os(iOS)
@testable import CmuxMobileAgentChat
import Foundation
import SwiftUI
import Testing
import UIKit

/// Diagnostic only (#47189 r8, not for the PR), round 2: List, Button and equatable each evaluate
/// one row per change; which part of the real SubagentsScreen makes every visible row evaluate. Each variant prints per-change row evaluations.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct SubagentRowDiagTests {
    init() { HostedTestWatchdog.start() }

    enum Variant: String, CaseIterable, Sendable { case real, realNoReceiver, realNoDestination, realNoOverlay, realStructEntries, realPlainAction, realStoreAgents }

    struct Screen: View {
        let store: AgentChatStore
        let variant: Variant
        @State private var selected: String?
        @State private var order = SubagentOrderMemo()

        struct Entry: Identifiable, Equatable {
            var agent: AgentSubagent
            var depth: Int
            var id: String { agent.id }
        }

        var body: some View {
            switch variant {
            case .real:
                SubagentsScreen(store: store, surface: AgentChatSurface())
            default:
                trimmed
            }
        }

        @ViewBuilder private var list: some View {
            List {
                switch variant {
                case .realStructEntries:
                    ForEach(order.ordered(store.subagents).map { Entry(agent: $0.agent, depth: $0.depth) }) { entry in
                        Button { selected = entry.agent.id } label: { row(entry.agent, entry.depth).equatable() }.buttonStyle(.cmuxPressFill)
                    }
                case .realPlainAction:
                    ForEach(order.ordered(store.subagents), id: \.agent.id) { entry in
                        Button {} label: { row(entry.agent, entry.depth).equatable() }.buttonStyle(.cmuxPressFill)
                    }
                case .realStoreAgents:
                    ForEach(store.subagents) { agent in
                        Button { selected = agent.id } label: { row(agent, 0).equatable() }.buttonStyle(.cmuxPressFill)
                    }
                default:
                    ForEach(order.ordered(store.subagents), id: \.agent.id) { entry in
                        Button { selected = entry.agent.id } label: { row(entry.agent, entry.depth).equatable() }.buttonStyle(.cmuxPressFill)
                    }
                }
            }
            .listStyle(.plain)
            .contentMargins(.top, 8, for: .scrollContent)
        }

        @ViewBuilder private var trimmed: some View {
            switch variant {
            case .realNoReceiver:
                list.overlay { if store.subagents.isEmpty { Text("None") } }
                    .navigationTitle("Subagents").navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(item: $selected) { Text($0) }
            case .realNoDestination:
                list.overlay { if store.subagents.isEmpty { Text("None") } }
                    .chatDemoReceiver(store: store, surface: AgentChatSurface())
                    .navigationTitle("Subagents").navigationBarTitleDisplayMode(.inline)
            case .realNoOverlay:
                list.chatDemoReceiver(store: store, surface: AgentChatSurface())
                    .navigationTitle("Subagents").navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(item: $selected) { Text($0) }
            default:
                list.overlay { if store.subagents.isEmpty { Text("None") } }
                    .chatDemoReceiver(store: store, surface: AgentChatSurface())
                    .navigationTitle("Subagents").navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(item: $selected) { Text($0) }
            }
        }

        func row(_ a: AgentSubagent, _ depth: Int) -> SubagentRow {
            SubagentRow(name: a.name, subtitle: a.action ?? "", state: a.state, startedAt: a.startedAt, endedAt: a.endedAt, depth: depth)
        }
    }

    @Test(arguments: Variant.allCases)
    func rowsPerChange(_ variant: Variant) async {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        let running = ListStressChatScreens.seedSubagents(store, count: 60)
        let probe = RenderProbe()
        let window = ListWorkCountersR4Tests.window(Screen(store: store, variant: variant), probe: probe)
        for _ in 0..<6 { await ListWorkCountersR4Tests.frame(window) }
        var per: [Int] = []
        var names: [String] = []
        for tick in 0..<3 {
            let before = probe.subagentRowBodies
            probe.subagentRowNames = []
            store.apply(.subagentUpdate(subagentID: running[0], .toolCall(ACPToolCall(id: "d-\(tick)", title: "Step \(tick)", kind: .execute))))
            for _ in 0..<3 { await ListWorkCountersR4Tests.frame(window) }
            per.append(probe.subagentRowBodies - before)
            names = probe.subagentRowNames
        }
        window.isHidden = true
        let line = "DIAG variant=\(variant.rawValue) per=\(per) last=\(names)"
        print(line)
        Attachment.record(line, named: "diag-\(variant.rawValue)")
        Issue.record(Comment(rawValue: line))
    }
}
#endif
