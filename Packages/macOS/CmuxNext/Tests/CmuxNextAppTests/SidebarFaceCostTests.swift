@testable import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// What mapping sidebar rows costs through the face batch (`SidebarMapping.FaceRowBatch`: `cmux_sidebar_face_rows`
/// over the mapping's reused `SidebarFaceBatch`, then the Swift row assembly). N workspaces (each with a few tabs of
/// mixed kinds: terminals, agent terminals, pages, agent chats, remote terminals, New Tab pages) map in one batch,
/// the way a full sidebar flush maps every row. It prints median and p95 per size, the per-row cost and the phases
/// (lines `SIDEBAR-FACE-COST`).
@MainActor @Suite(.serialized) struct SidebarFaceCostTests {
    typealias Request = SidebarMapping.FaceRowRequest

    static let home = NSHomeDirectory()
    static let newTabTitle = "New Tab"
    static let selectedTab: (PaneModel) -> String? = { pane in
        pane.tabs.count > 1 && pane.focusedAt % 2 == 1 ? pane.tabs.last?.id : nil
    }
    static let pageFace: (WorkspaceModel, TabModel, TabModel?) -> SidebarMapping.PageFace? = { _, tab, _ in
        tab.kind == .browser ? SidebarMapping.PageFace(title: tab.titleText) : nil
    }
    static let notificationText: (TabModel) -> String? = { tab in
        tab.notification.map { "Notification \($0.notification.rawValue)" }
    }

    static let options = SidebarMapping.FaceOptions(machine: .local, selectedTab: selectedTab, newTabTitle: newTabTitle, pageFace: pageFace,
                                                    notificationText: notificationText)

    // MARK: Fixture

    /// Workspace `index`: two panes (on two screens), two to four tabs, eight variants of what they hold.
    static func request(_ index: Int) -> Request {
        let variant = index % 8
        var surface = UInt64(index) * 16
        func next() -> SurfaceID {
            surface += 1
            return SurfaceID(rawValue: surface)
        }
        let project = "\(home)/fun/project-\(index)"
        let terminalTitle = switch variant {
        case 0: "zsh"
        case 1: project
        case 2: "~/fun/project-\(index)"
        default: "npm run dev"
        }
        var first = [TabSnapshot(surface: next(), kind: .pty, title: terminalTitle, cwd: project, gitBranch: "feature-\(index)")]
        first.append(TabSnapshot(surface: next(), kind: .browser, title: "PR \(index)", url: "https://github.com/manaflow-ai/cmux/pull/\(index)"))
        var second: [TabSnapshot] = []
        if variant.isMultiple(of: 2) {
            var chat = TabSnapshot(surface: next(), kind: .conversation, title: "Chat \(index)")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:local", session: "s-\(index)",
                                                                                 harness: variant == 2 ? "codex" : "claude"))
            second.append(chat)
        }
        let notification = index.isMultiple(of: 3)
            ? TabNotification(notification: .init(rawValue: UInt64(index + 1)), unread: true, createdAtMs: 1_700_000_000_000 + UInt64(index))
            : nil
        second.append(TabSnapshot(surface: next(), kind: .pty, name: variant == 3 ? "server" : nil, title: variant == 5 ? "/home/cmux/work" : "~",
                                  notification: notification, cwd: variant == 5 ? "/home/cmux/work" : home))
        if variant == 6 {
            second.append(TabSnapshot(surface: next(), kind: .remoteTerminal, title: "/home/cmux/src/", cwd: "/home/cmux/src"))
        }
        let panes = [
            PaneSnapshot(id: .init(rawValue: UInt64(index * 2 + 1)), activeTab: variant == 4 ? 1 : 0, focusedAt: UInt64(index % 5), tabs: first),
            PaneSnapshot(id: .init(rawValue: UInt64(index * 2 + 2)), focusedAt: UInt64((index + 2) % 5), tabs: second),
        ]
        let screens = panes.map { ScreenSnapshot(id: .init(rawValue: $0.id.rawValue), layout: .leaf($0.id), panes: [$0]) }
        let resource = ResourceID(rawValue: "ws-\(index)")
        let workspace = WorkspaceModel(WorkspaceSnapshot(
            id: .init(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: "k-\(index)"), resourceID: resource,
            name: index.isMultiple(of: 4) ? "workspace-\(index)" : "project-\(index)", screens: screens,
            color: variant == 1 ? "blue" : nil, markedUnread: variant == 7))
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let terminal = tabs[0]
        switch variant {
        case 1, 5:
            terminal.setAgent(AgentStatus(surface: terminal.surface, state: variant == 1 ? .working : .idle, agent: "claude",
                                          updatedAtMs: 1_700_000_100_000 + UInt64(index)))
        case 3:
            terminal.applyState(SessionStateMirror.TabRecord(markedUnread: true), progress: TerminalProgressReport(state: .normal, value: 40),
                                commandSinceMs: 1_700_000_000_000)
        case 4:
            terminal.applyState(SessionStateMirror.TabRecord(attention: TabAttention(reason: "Approve the deploy", atMs: 5_000 + UInt64(index))),
                                progress: TerminalProgressReport(state: .error))
        case 6:
            terminal.applyState(nil, progress: TerminalProgressReport(state: .indeterminate))
        default:
            break
        }
        if index.isMultiple(of: 3) {
            workspace.status = WorkspaceStatus(
                workspaceID: resource,
                entries: [.init(key: SidebarMapping.portsKey, text: "3000"), .init(key: SidebarMapping.pullRequestKey, text: "#\(index)"),
                          .init(key: "build", text: "Building"), .init(key: "tests", text: index.isMultiple(of: 2) ? "" : "412 passed")],
                progress: variant == 2 ? WorkspaceStatus.Progress(value: 0.5) : nil)
        }
        let newTabPages: Set<String> = variant == 7 ? [tabs[1].id] : []
        return Request(workspace: workspace, status: index.isMultiple(of: 5) ? "Running tests" : nil, muted: index.isMultiple(of: 11),
                       newTabPages: newTabPages)
    }

    static func requests(_ count: Int) -> [Request] { (0 ..< count).map(request) }

    // MARK: Cost

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    static func stats(_ values: [Double]) -> (median: Double, p95: Double) {
        let sorted = values.sorted()
        let p95 = sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1))]
        return (sorted[sorted.count / 2], p95)
    }

    static func format(_ value: Double) -> String { String(format: "%.3f", value) }

    @Test func mappingEveryRowThroughTheFaceBatch() throws {
        let clock = ContinuousClock()
        let mapping = SidebarMapping.shared
        #if DEBUG
        let configuration = "debug-define"
        #else
        let configuration = "no-debug-define"
        #endif
        print("SIDEBAR-FACE-COST config=\(configuration) env=\(ProcessInfo.processInfo.environment["CMUX_SWIFT_SUITE_CONFIGURATION"] ?? "debug")")
        var sink = 0
        for count in [50, 200, 5000] {
            let requests = Self.requests(count)
            let rounds = count >= 5000 ? 9 : 31
            // Warm the path (first-call allocations, the handle's reply buffers, lazy statics).
            sink &+= try #require(mapping.faceRows(requests, options: Self.options)).count
            var total: [Double] = [], stage: [Double] = [], run: [Double] = [], finish: [Double] = []
            for _ in 0 ..< rounds {
                // The batch's phases as the feed runs them: every row staged (encoded), one call (and decode), every row finished.
                let started = clock.now
                let batch = SidebarMapping.FaceRowBatch(mapping: mapping, options: Self.options)
                batch.begin()
                let slots = requests.map(batch.stage)
                let staged = clock.now
                try #require(batch.run(), "the face rules read the batch")
                let ran = clock.now
                for slot in slots { sink &+= batch.finish(slot).tabs.count }
                let finished = clock.now
                total.append(Self.milliseconds(finished - started))
                stage.append(Self.milliseconds(staged - started))
                run.append(Self.milliseconds(ran - staged))
                finish.append(Self.milliseconds(finished - ran))
            }
            let perRow = { (ms: Double) in Self.format(ms * 1000 / Double(count)) }
            let all = Self.stats(total)
            print("SIDEBAR-FACE-COST n=\(count) rounds=\(rounds) batch median=\(Self.format(all.median))ms p95=\(Self.format(all.p95))ms"
                + " per_row=\(perRow(all.median))us")
            let phases = [("stage", stage), ("run", run), ("finish", finish)].map { name, values in
                let stat = Self.stats(values)
                return "\(name) median=\(Self.format(stat.median))ms p95=\(Self.format(stat.p95))ms (\(perRow(stat.median))us/row)"
            }
            print("SIDEBAR-FACE-COST n=\(count) phases: \(phases.joined(separator: " "))")
        }
        #expect(sink > 0)
    }
}
