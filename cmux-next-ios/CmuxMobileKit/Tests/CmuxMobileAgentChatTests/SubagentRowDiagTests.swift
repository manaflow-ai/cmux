#if os(iOS)
@testable import CmuxMobileAgentChat
import Foundation
import SwiftUI
import Testing
import UIKit

/// Diagnostic only (#47189 r8, not for the PR): which container makes every visible Subagents
/// row evaluate on one subagent's change. Each variant prints per-change row evaluations.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct SubagentRowDiagTests {
    init() { HostedTestWatchdog.start() }

    enum Variant: String, CaseIterable, Sendable { case listButton, listPlain, lazyButton, lazyPlain, listButtonNoEquatable, listIDs }

    struct Screen: View {
        let store: AgentChatStore
        let variant: Variant
        var body: some View {
            switch variant {
            case .listButton:
                List { ForEach(store.subagents) { a in Button {} label: { row(a).equatable() }.buttonStyle(.cmuxPressFill) } }.listStyle(.plain)
            case .listPlain:
                List { ForEach(store.subagents) { a in row(a).equatable() } }.listStyle(.plain)
            case .lazyButton:
                ScrollView { LazyVStack { ForEach(store.subagents) { a in Button {} label: { row(a).equatable() }.buttonStyle(.cmuxPressFill) } } }
            case .lazyPlain:
                ScrollView { LazyVStack { ForEach(store.subagents) { a in row(a).equatable() } } }
            case .listButtonNoEquatable:
                List { ForEach(store.subagents) { a in Button {} label: { row(a) }.buttonStyle(.cmuxPressFill) } }.listStyle(.plain)
            case .listIDs:
                List { ForEach(store.subagents.map(\.id), id: \.self) { id in Cell(store: store, id: id) } }.listStyle(.plain)
            }
        }
        func row(_ a: AgentSubagent) -> SubagentRow {
            SubagentRow(name: a.name, subtitle: a.action ?? "", state: a.state, startedAt: a.startedAt, endedAt: a.endedAt, depth: 0)
        }
    }

    struct Cell: View {
        let store: AgentChatStore
        let id: String
        var body: some View {
            if let a = store.subagent(id) {
                SubagentRow(name: a.name, subtitle: a.action ?? "", state: a.state, startedAt: a.startedAt, endedAt: a.endedAt, depth: 0)
                    .equatable()
            }
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
