@testable import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Whether the sidebar row face can move from Swift (`SidebarMapping.row`) to the Rust rules
/// (`cmux_sidebar_face_rows`, `SidebarFaceBatch`) at least as fast. N workspaces (each with a few tabs of mixed
/// kinds: terminals, agent terminals, pages, agent chats, remote terminals, New Tab pages) are mapped all at once,
/// the way a full sidebar flush maps every row: with `row` one by one, and with `faceRows` in one Rust call. It
/// prints median and p95 per size (lines `SIDEBAR-FACE-COST`) and checks that both give the same rows.
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

    /// Fields the Rust face decides (directly or through the tab it picks), and the ones it does not cover.
    static let covered = [
        "directory", "branch (folder tab)", "process", "status", "ports", "pullRequest", "lastActivity", "rowKind", "kind",
        "kindBrand (face tab)", "unread", "progress", "folder (bucket)", "focusedTab", "agentName/agentBrand (agent tab)",
        "notificationText (notice tab)", "lastMessage (chat tab)", "title/icon (face tab's page face)",
        "tabs[].title", "tabs[].kind", "tabs[].folder", "tabs[].lastActivity", "tabs[].state/host (New Tab blank)",
        "status block entry filter (kept entries)",
    ]
    static let notCovered = [
        "title text and favicon (pageFace: browser runtime)", "icon/color (workspace record, iconAsset)",
        "activity/activityStyle/agentWorking/activityFromProgram (StatusMapping)", "presence", "audio",
        "isUnnamed/homeShellName/chief task title", "workspaceDescription/taskStatus/checklist", "detail (hover card)",
        "reported block (icons, log line, progress label)", "agentIcon (harness icon art)",
        "lastMessage and notification text (turn store, notification store)",
        "tabs[].favicon/host/path/model/command/machine/branch/brand/isUnread/state/subagents/commands/isFreed",
    ]

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

    // MARK: The two paths

    static func swiftRows(_ requests: [Request], machine: MachineID, homeShellTitle: String? = nil) -> [SidebarWorkspace] {
        let mapping = SidebarMapping.shared
        return requests.map { request in
            mapping.row(request.workspace, machine: machine, status: request.status, showsUnread: true, muted: request.muted,
                        selectedTab: selectedTab, newTabPages: request.newTabPages, newTabTitle: newTabTitle, pageFace: pageFace,
                        notificationText: notificationText, homeShellTitle: homeShellTitle)
        }
    }

    static func faceRows(_ requests: [Request], batch: SidebarFaceBatch, machine: MachineID, homeShellTitle: String? = nil) -> [SidebarWorkspace] {
        SidebarMapping.shared.faceRows(requests, batch: batch, machine: machine, showsUnread: true, selectedTab: selectedTab,
                                       newTabTitle: newTabTitle, pageFace: pageFace, notificationText: notificationText,
                                       homeShellTitle: homeShellTitle) ?? []
    }

    static func encode(_ requests: [Request], batch: SidebarFaceBatch, machine: MachineID) {
        SidebarMapping.shared.encodeFaces(requests, into: batch, machine: machine, showsUnread: true, selectedTab: selectedTab,
                                          newTabTitle: newTabTitle, tabTitle: nil, harnessIcons: .none)
    }

    /// The face as `row` decides it today, in Swift: the same rules, read out of the mapping's own helpers.
    static func swiftFace(_ request: Request, machine: MachineID) -> SidebarFace {
        let mapping = SidebarMapping.shared, workspace = request.workspace, newTabPages = request.newTabPages
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        func index(_ tab: TabModel?) -> Int? { tab.flatMap { tab in tabs.firstIndex { $0 === tab } } }
        let shorten: (String) -> String = machine == .local ? { mapping.abbreviate($0) } : SidebarMapping.abbreviateRemote
        let focused = mapping.frontTab(workspace, selectedTab: selectedTab)
        let label = mapping.labelTab(focused, tabs, newTabPages: newTabPages)
        let face = mapping.faceTab(workspace, selectedTab: selectedTab, newTabPages: newTabPages)
        let folder = mapping.folderTab(tabs, label: label)
        let bucket = focused?.cwd != nil ? focused : tabs.first { $0.cwd != nil }
        var result = SidebarFace()
        result.front = index(focused)
        result.label = index(label)
        result.face = index(face)
        result.work = index(mapping.workTab(workspace, selectedTab: selectedTab))
        result.chat = index(mapping.chatTab(label, tabs))
        result.folderTab = index(folder)
        result.bucketTab = index(bucket)
        result.agent = index(mapping.agentTab(tabs))
        var attention: (index: Int, at: UInt64)?
        for (position, tab) in tabs.enumerated() {
            if let at = tab.attention?.atMs, attention.map({ at > $0.at }) ?? true { attention = (position, at) }
        }
        if let attention {
            result.notice = .attention(attention.index)
        } else if let unread = index(mapping.newestUnread(tabs)) {
            result.notice = .notification(unread)
        }
        result.kind = mapping.kind(face)
        result.rowKind = mapping.rowKind(tabs)
        result.unread = workspace.unreadCount > 0 ? 2
            : (workspace.markedUnread || tabs.contains { $0.markedUnread || $0.attention != nil }) ? 1 : 0
        result.progress = mapping.progress(workspace, tabs: tabs)
        result.directory = folder?.cwd.map(shorten)
        result.bucket = bucket?.cwd.map(shorten)
        result.process = mapping.process(label)
        let entries = workspace.status?.entries ?? []
        result.statusLine = (request.status ?? SidebarMapping.statusLine(entries)).flatMap { $0.isEmpty ? nil : $0 }
        result.ports = entries.firstIndex { $0.key == SidebarMapping.portsKey && !$0.text.isEmpty }
        result.pullRequest = entries.firstIndex { $0.key == SidebarMapping.pullRequestKey && !$0.text.isEmpty }
        result.statusEntries = entries.indices.filter { entries[$0].key != SidebarMapping.portsKey && entries[$0].key != SidebarMapping.pullRequestKey }
        result.lastActivityMs = tabs.map { max($0.agent?.updatedAtMs ?? 0, $0.notification?.createdAtMs ?? 0) }.max() ?? 0
        result.listed = tabs.map { tab in
            let blank = newTabPages.contains(tab.id) && !newTabTitle.isEmpty
            let listTitle = SidebarMapping.listTitle(tab, of: workspace, newTabPages: newTabPages, newTabTitle: newTabTitle, tabTitle: nil)
            let title = SidebarMapping.shortenedPath(listTitle, of: tab, shorten: shorten)
            return SidebarFace.Listed(
                title: title == listTitle ? nil : title,
                folder: blank ? nil : tab.cwd.flatMap { $0.isEmpty ? nil : shorten($0) },
                kind: newTabPages.contains(tab.id) ? 1 : tab.agentSession != nil ? 2 : 0,
                blank: blank,
                lastActivityMs: max(tab.agent?.updatedAtMs ?? 0, tab.notification?.createdAtMs ?? 0))
        }
        return result
    }

    // MARK: Parity

    /// The labels of the stored properties where `a` and `b` differ (one level deep, tabs by index).
    static func differences(_ a: SidebarWorkspace, _ b: SidebarWorkspace) -> [String] {
        guard a != b else { return [] }
        var labels: [String] = []
        for (left, right) in zip(Mirror(reflecting: a).children, Mirror(reflecting: b).children) {
            let label = left.label ?? "?"
            if label == "tabs" {
                for (position, pair) in zip(a.tabs, b.tabs).enumerated() where pair.0 != pair.1 {
                    for (l, r) in zip(Mirror(reflecting: pair.0).children, Mirror(reflecting: pair.1).children)
                        where String(describing: l.value) != String(describing: r.value) {
                        labels.append("tabs[\(position)].\(l.label ?? "?"): \(l.value) vs \(r.value)")
                    }
                }
                if a.tabs.count != b.tabs.count { labels.append("tabs.count \(a.tabs.count) vs \(b.tabs.count)") }
            } else if String(describing: left.value) != String(describing: right.value) {
                labels.append("\(label): \(left.value) vs \(right.value)")
            }
        }
        return labels.isEmpty ? ["(rows differ in a field Mirror does not show)"] : labels
    }

    @Test func rustFacesAndRowsMatchSwift() throws {
        let requests = Self.requests(400)
        let batch = SidebarFaceBatch()
        for (machine, homeShellTitle) in [(MachineID.local, nil as String?), (MachineID("cloud-1"), "Terminal")] {
            Self.encode(requests, batch: batch, machine: machine)
            let rust = try #require(SidebarMapping.shared.decodeFaces(batch), "the face rules read the request")
            var faceMismatches: [String] = []
            for (index, request) in requests.enumerated() {
                let swift = Self.swiftFace(request, machine: machine)
                if swift != rust[index] { faceMismatches.append("row \(index) (variant \(index % 8)): swift \(swift) rust \(rust[index])") }
            }
            let swiftRows = Self.swiftRows(requests, machine: machine, homeShellTitle: homeShellTitle)
            let faceRows = Self.faceRows(requests, batch: batch, machine: machine, homeShellTitle: homeShellTitle)
            try #require(faceRows.count == swiftRows.count)
            var rowMismatches: [String] = []
            for (index, pair) in zip(swiftRows, faceRows).enumerated() {
                let diff = Self.differences(pair.0, pair.1)
                if !diff.isEmpty { rowMismatches.append("row \(index) (variant \(index % 8)): \(diff.joined(separator: "; "))") }
            }
            print("SIDEBAR-FACE-PARITY machine=\(machine) rows=\(requests.count) face_mismatches=\(faceMismatches.count) row_mismatches=\(rowMismatches.count)")
            for line in (faceMismatches.prefix(5) + rowMismatches.prefix(5)) { print("SIDEBAR-FACE-PARITY mismatch \(line)") }
            #expect(faceMismatches.isEmpty, "\(faceMismatches.prefix(3))")
            #expect(rowMismatches.isEmpty, "\(rowMismatches.prefix(3))")
        }
        print("SIDEBAR-FACE-PARITY covered: \(Self.covered.joined(separator: ", "))")
        print("SIDEBAR-FACE-PARITY not covered (Swift in both paths): \(Self.notCovered.joined(separator: ", "))")
    }

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

    @Test func mappingEveryRowCostsInSwiftAndThroughTheFace() throws {
        let clock = ContinuousClock()
        let mapping = SidebarMapping.shared
        let batch = SidebarFaceBatch()
        let machine = MachineID.local
        #if DEBUG
        let configuration = "debug-define"
        #else
        let configuration = "no-debug-define"
        #endif
        print("SIDEBAR-FACE-COST config=\(configuration) env=\(ProcessInfo.processInfo.environment["CMUX_SWIFT_SUITE_CONFIGURATION"] ?? "debug")")
        var sink = 0
        for count in [50, 200, 1000, 5000] {
            let requests = Self.requests(count)
            let rounds = count >= 5000 ? 9 : count >= 1000 ? 15 : 31
            // Warm both paths (first-call allocations, the handle's reply buffers, lazy statics).
            sink &+= Self.swiftRows(requests, machine: machine).count
            sink &+= Self.faceRows(requests, batch: batch, machine: machine).count
            var swiftRow: [Double] = [], faceRow: [Double] = [], swiftFace: [Double] = [], faceOnly: [Double] = []
            var encode: [Double] = [], call: [Double] = [], decode: [Double] = [], assemble: [Double] = []
            for _ in 0 ..< rounds {
                var started = clock.now
                sink &+= Self.swiftRows(requests, machine: machine).count
                swiftRow.append(Self.milliseconds(clock.now - started))

                started = clock.now
                sink &+= Self.faceRows(requests, batch: batch, machine: machine).count
                faceRow.append(Self.milliseconds(clock.now - started))

                started = clock.now
                for request in requests { sink &+= Self.swiftFace(request, machine: machine).listed.count }
                swiftFace.append(Self.milliseconds(clock.now - started))

                // The adapter's phases: encode, the one call, decode every face, then the Swift row assembly.
                started = clock.now
                Self.encode(requests, batch: batch, machine: machine)
                let encoded = clock.now
                let reply = try #require(batch.run())
                let called = clock.now
                let faces = (0 ..< batch.count).map { reply.face($0, tabCount: batch.tabRange($0).count) }
                let decoded = clock.now
                for (index, request) in requests.enumerated() {
                    let range = batch.tabRange(index)
                    sink &+= mapping.faceRow(request, face: faces[index], tabs: Array(batch.tabs[range]), listTitles: Array(batch.listTitles[range]),
                                             machine: machine, showsUnread: true, newTabTitle: Self.newTabTitle, pageFace: Self.pageFace,
                                             notificationText: Self.notificationText, iconAsset: { _ in nil }, harnessIcons: .none,
                                             homeShellTitle: nil).tabs.count
                }
                let assembled = clock.now
                encode.append(Self.milliseconds(encoded - started))
                call.append(Self.milliseconds(called - encoded))
                decode.append(Self.milliseconds(decoded - called))
                assemble.append(Self.milliseconds(assembled - decoded))
                faceOnly.append(Self.milliseconds(decoded - started))
            }
            let perRow = { (ms: Double) in Self.format(ms * 1000 / Double(count)) }
            let swift = Self.stats(swiftRow), face = Self.stats(faceRow)
            let swiftOnlyFace = Self.stats(swiftFace), rustFace = Self.stats(faceOnly)
            let tabs = batch.tabs.count
            print("SIDEBAR-FACE-COST n=\(count) tabs=\(tabs) rounds=\(rounds) row: swift median=\(Self.format(swift.median))ms p95=\(Self.format(swift.p95))ms"
                + " adapter median=\(Self.format(face.median))ms p95=\(Self.format(face.p95))ms"
                + " adapter/swift=\(Self.format(face.median / swift.median)) per_row swift=\(perRow(swift.median))us adapter=\(perRow(face.median))us")
            print("SIDEBAR-FACE-COST n=\(count) face-only: swift median=\(Self.format(swiftOnlyFace.median))ms p95=\(Self.format(swiftOnlyFace.p95))ms"
                + " rust(encode+call+decode) median=\(Self.format(rustFace.median))ms p95=\(Self.format(rustFace.p95))ms"
                + " rust/swift=\(Self.format(rustFace.median / swiftOnlyFace.median))")
            let phases = [("encode", encode), ("call", call), ("decode", decode), ("assemble", assemble)].map { name, values in
                let stat = Self.stats(values)
                return "\(name) median=\(Self.format(stat.median))ms p95=\(Self.format(stat.p95))ms (\(perRow(stat.median))us/row)"
            }
            print("SIDEBAR-FACE-COST n=\(count) adapter phases: \(phases.joined(separator: " "))")
        }
        #expect(sink > 0)
    }
}
