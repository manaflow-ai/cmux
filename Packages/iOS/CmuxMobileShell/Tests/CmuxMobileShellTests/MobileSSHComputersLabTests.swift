import CMUXMobileCore
@testable import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing

/// Drives the SSH runtime the way the app does (host + key, prompts,
/// workspace list, attach, typing, output) against the local sshd lab.
/// Run with `CMUX_SSH_LAB=/tmp/cmux-ssh-lab`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct MobileSSHComputersLabTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""

    @Test(arguments: [SSHPersistenceMode.plain, .tmux, .cmuxTUI])
    func workspaceAttachTypeAndSeeOutput(mode: SSHPersistenceMode) async throws {
        let (computers, sink, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        let answering = autoAnswer(computers, persistence: mode)
        defer { answering.cancel() }

        await computers.open(hostID: host.id)
        #expect(computers.statusByHost[host.id] == .connected)
        let scoped = try #require(await computers.createWorkspace(hostID: host.id))
        let state = try #require(sink.states.last)
        let row = try #require(state.workspaces.first { $0.id.rawValue == scoped })
        let surface = try #require(row.terminals.first).id.rawValue

        computers.viewportChanged(surfaceID: surface, columns: 90, rows: 30)
        computers.replay(surfaceID: surface)
        try await sink.waitForOutput(surface) { !$0.isEmpty }
        computers.input(Data("stty size; echo ssh-$((6*7))\r".utf8), surfaceID: surface)
        // tmux control mode has no status line: a single-pane window is
        // sized to the phone's grid exactly.
        try await sink.waitForOutput(surface) { $0.contains("ssh-42") && $0.contains("30 90") }

        if mode != .plain {
            // Persistence: drop the connection, reconnect, reattach, and the
            // earlier output is still there (tmux redraw / cmux-tui vt-state).
            await computers.disconnect(hostID: host.id)
            sink.outputs[surface] = ""
            await computers.open(hostID: host.id)
            #expect(sink.states.last?.workspaces.contains { $0.id.rawValue == scoped } == true)
            computers.replay(surfaceID: surface)
            try await sink.waitForOutput(surface) { $0.contains("ssh-42") }
        }
        await computers.closeWorkspace(scopedID: scoped)
        #expect(sink.states.last?.workspaces.contains { $0.id.rawValue == scoped } != true)
    }

    @Test func unknownHostKeyIsAskedOnceThenPinned() async throws {
        let (computers, _, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        var trustPrompts = 0
        let answering = Task { @MainActor in
            while !Task.isCancelled {
                for prompt in computers.prompts {
                    switch prompt {
                    case .trustNewHostKey:
                        trustPrompts += 1
                        computers.answer(prompt, with: .trust)
                    case .choosePersistence:
                        computers.answer(prompt, with: .persistence(.plain))
                    case .hostKeyChanged:
                        computers.answer(prompt, with: .cancel)
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        await computers.disconnect(hostID: host.id)
        await computers.open(hostID: host.id)
        #expect(trustPrompts == 1)
        #expect(computers.statusByHost[host.id] == .connected)
    }

    @Test func changedHostKeyStopsWhenDeclined() async throws {
        let (computers, _, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        await computers.hostStore.pin(SSHHostKey(openSSHString: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld"), for: host.endpoint.hostKeyIdentity)
        var sawChanged = false
        let answering = Task { @MainActor in
            while !Task.isCancelled {
                for prompt in computers.prompts {
                    if case .hostKeyChanged = prompt { sawChanged = true }
                    computers.answer(prompt, with: .cancel)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        #expect(sawChanged)
        guard case .failed = computers.statusByHost[host.id] else {
            Issue.record("expected failed status, got \(String(describing: computers.statusByHost[host.id]))")
            return
        }
    }

    /// Reattaching to a cmux-tui terminal restores lines that scrolled off
    /// the screen before the disconnect: the `vt-state` snapshot carries the
    /// retained primary-screen scrollback, and the phone writes it after its
    /// reset so it lands in local scrollback.
    @Test(.timeLimit(.minutes(2))) func cmuxTUIReattachRestoresScrolledOffHistory() async throws {
        let (computers, sink, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        let answering = autoAnswer(computers, persistence: .cmuxTUI)
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        let scoped = try #require(await computers.createWorkspace(hostID: host.id))
        defer { Task { @MainActor in await computers.closeWorkspace(scopedID: scoped) } }
        let surface = try #require(sink.states.last?.workspaces.first { $0.id.rawValue == scoped }?.terminals.first).id.rawValue

        computers.viewportChanged(surfaceID: surface, columns: 80, rows: 10)
        computers.replay(surfaceID: surface)
        try await sink.waitForOutput(surface) { !$0.isEmpty }
        computers.input(Data("for i in $(seq 1 40); do echo hist-$i; done\r".utf8), surfaceID: surface)
        try await sink.waitForOutput(surface) { $0.contains("hist-40\r\n") }

        await computers.disconnect(hostID: host.id)
        sink.outputs[surface] = ""
        await computers.open(hostID: host.id)
        computers.replay(surfaceID: surface)
        try await sink.waitForOutput(surface) { Self.afterLastReset($0).contains("hist-40\r\n") }
        // hist-3 scrolled off a 10-row screen long before the disconnect.
        #expect(Self.afterLastReset(sink.outputs[surface] ?? "").contains("\r\nhist-3\r\n"))
    }

    /// The text after the last full reset (RIS) the runtime sent.
    static func afterLastReset(_ output: String) -> String {
        guard let range = output.range(of: "\u{1B}c", options: .backwards) else { return output }
        return String(output[range.upperBound...])
    }

    /// Declining a changed key on the JUMP host fails both hosts with the
    /// rejection (not a timeout), and the jump host does not stay
    /// "connecting".
    @Test func declinedJumpHostKeyReportsRejectionOnBothHosts() async throws {
        let (computers, _, jump) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: jump) } }
        var target = SSHHostRecord(name: "Behind jump", endpoint: jump.endpoint, keyID: jump.keyID)
        target.jumpHostID = jump.id
        try await computers.saveHost(target)
        await computers.hostStore.pin(SSHHostKey(openSSHString: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld"), for: jump.endpoint.hostKeyIdentity)
        let answering = Task { @MainActor in
            while !Task.isCancelled {
                for prompt in computers.prompts { computers.answer(prompt, with: .cancel) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { answering.cancel() }
        await computers.open(hostID: target.id)
        #expect(computers.statusByHost[target.id] == .failed(L10nSSH.hostKeyRejected))
        #expect(computers.statusByHost[jump.id] == .failed(L10nSSH.hostKeyRejected))
        try? await computers.deleteHost(id: target.id)
    }

    // MARK: tmux control mode

    /// A tmux session split server-side lists as one workspace with one tab
    /// per pane; each pane surface is seeded from `capture-pane` with that
    /// pane's own content, pinned to the pane's layout grid, and typing into
    /// pane 2 reaches only pane 2.
    @Test(.timeLimit(.minutes(2))) func tmuxSplitWindowPanesAreSeparateTabs() async throws {
        let session = "cmux-lab-split-\(UUID().uuidString.prefix(6))"
        Self.tmux("new-session", "-d", "-s", session, "-x", "120", "-y", "40")
        defer { Self.tmux("kill-session", "-t", "=" + session) }
        Self.tmux("split-window", "-h", "-t", "=" + session + ":")
        let panes = Self.tmux("list-panes", "-t", "=" + session + ":", "-F", "#{pane_id}").split(separator: "\n").map(String.init)
        try #require(panes.count == 2)
        Self.tmux("send-keys", "-t", panes[0], "echo left-$((40+2))", "Enter")
        Self.tmux("send-keys", "-t", panes[1], "echo right-$((50+2))", "Enter")
        try await Self.waitUntil { Self.tmux("capture-pane", "-p", "-t", panes[1]).contains("right-52") }

        let (computers, sink, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        let answering = autoAnswer(computers, persistence: .tmux)
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        let row = try #require(sink.states.last?.workspaces.first { MobileSSHIdentifiers.localID(of: $0.id.rawValue) == session })
        #expect(row.terminals.count == 2)
        let left = try #require(row.terminals.first).id.rawValue
        let right = try #require(row.terminals.last).id.rawValue
        #expect(MobileSSHIdentifiers.localID(of: right) == "\(session)/\(panes[1])")

        for surface in [left, right] {
            computers.viewportChanged(surfaceID: surface, columns: 90, rows: 30)
            computers.replay(surfaceID: surface)
        }
        try await sink.waitForOutput(left) { Self.afterLastReset($0).contains("left-42") }
        try await sink.waitForOutput(right) { Self.afterLastReset($0).contains("right-52") }
        #expect(!Self.afterLastReset(sink.outputs[left] ?? "").contains("right-52"))
        #expect(!Self.afterLastReset(sink.outputs[right] ?? "").contains("left-42"))
        // The phone's grid sized the window (90x30); each pane renders at its
        // half of it, so the surfaces pin to the pane grid and letterbox.
        try await Self.waitUntil { computers.remoteGrid(surfaceID: right).map { $0.rows == 30 && $0.columns < 90 } ?? false }
        #expect((sink.viewportApplications[right] ?? 0) > 0)

        computers.input(Data("echo only-$((6*6))\r".utf8), surfaceID: right)
        try await sink.waitForOutput(right) { $0.contains("only-36") }
        try await Self.waitUntil { Self.tmux("capture-pane", "-p", "-t", panes[1]).contains("only-36") }
        #expect(!Self.tmux("capture-pane", "-p", "-t", panes[0]).contains("only-"))
        #expect(!(sink.outputs[left] ?? "").contains("only-36"))
    }

    /// The phone attaches through its own grouped session, so the session's
    /// current window (what a laptop sees) never changes, even when the phone
    /// opens a window; the grouped session disappears when the phone detaches.
    @Test(.timeLimit(.minutes(2))) func tmuxNewTabOpensWindowWithoutMovingLaptop() async throws {
        let (computers, sink, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        let answering = autoAnswer(computers, persistence: .tmux)
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        let scoped = try #require(await computers.createWorkspace(hostID: host.id))
        let session = try #require(MobileSSHIdentifiers.localID(of: scoped))
        defer { Self.tmux("kill-session", "-t", "=" + session) }
        #expect(computers.supportsTerminalTabs(workspaceID: scoped))

        let first = try #require(sink.states.last?.workspaces.first { $0.id.rawValue == scoped }?.terminals.first).id.rawValue
        computers.viewportChanged(surfaceID: first, columns: 80, rows: 24)
        computers.replay(surfaceID: first)
        try await sink.waitForOutput(first) { !Self.afterLastReset($0).isEmpty }
        let currentWindow = Self.tmux("display-message", "-p", "-t", "=" + session + ":", "#{window_id}")

        // The phone's own grouped session exists while attached.
        let sessions = Self.tmux("list-sessions", "-F", "#{session_name} #{session_group}")
        #expect(sessions.contains("\(session)\(MobileSSHTmuxControlClient.groupedSessionMarker)"))

        let created = try #require(await computers.createTerminal(inWorkspace: scoped))
        let terminals = try #require(sink.states.last?.workspaces.first { $0.id.rawValue == scoped }?.terminals)
        #expect(terminals.count == 2)
        #expect(terminals.last?.id.rawValue == created)
        #expect(Self.tmux("list-windows", "-t", "=" + session, "-F", "#{window_id}").split(separator: "\n").count == 2)
        computers.viewportChanged(surfaceID: created, columns: 80, rows: 24)
        computers.replay(surfaceID: created)
        computers.input(Data("echo newtab-$((7*7))\r".utf8), surfaceID: created)
        try await sink.waitForOutput(created) { $0.contains("newtab-49") }
        // Truecolor is advertised in windows the phone opens.
        computers.input(Data("echo ct=$COLORTERM\r".utf8), surfaceID: created)
        try await sink.waitForOutput(created) { $0.contains("ct=truecolor") }
        #expect(Self.tmux("display-message", "-p", "-t", "=" + session + ":", "#{window_id}") == currentWindow)

        // Detach + reattach: capture restores the pane content.
        await computers.disconnect(hostID: host.id)
        try await Self.waitUntil { !Self.tmux("list-sessions", "-F", "#{session_name}").contains(MobileSSHTmuxControlClient.groupedSessionMarker) }
        sink.outputs[created] = ""
        await computers.open(hostID: host.id)
        computers.replay(surfaceID: created)
        try await sink.waitForOutput(created) { Self.afterLastReset($0).contains("newtab-49") }
        #expect(Self.tmux("display-message", "-p", "-t", "=" + session + ":", "#{window_id}") == currentWindow)
        await computers.closeWorkspace(scopedID: scoped)
        #expect(!Self.tmux("list-sessions", "-F", "#{session_name}").contains(session))
    }

    /// Output from a window the phone is not looking at still reaches its
    /// pane surface (control mode covers every window of the session), and a
    /// server-side split shows up as a new tab without reattaching.
    @Test(.timeLimit(.minutes(2))) func tmuxControlModeCoversAllWindowsAndTopology() async throws {
        let session = "cmux-lab-topo-\(UUID().uuidString.prefix(6))"
        Self.tmux("new-session", "-d", "-s", session)
        defer { Self.tmux("kill-session", "-t", "=" + session) }
        Self.tmux("new-window", "-d", "-t", "=" + session + ":")
        let (computers, sink, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        let answering = autoAnswer(computers, persistence: .tmux)
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        let row = try #require(sink.states.last?.workspaces.first { MobileSSHIdentifiers.localID(of: $0.id.rawValue) == session })
        try #require(row.terminals.count == 2)
        let second = row.terminals[1].id.rawValue
        for terminal in row.terminals {
            computers.viewportChanged(surfaceID: terminal.id.rawValue, columns: 80, rows: 24)
            computers.replay(surfaceID: terminal.id.rawValue)
        }
        try await sink.waitForOutput(second) { !Self.afterLastReset($0).isEmpty }
        let pane = try #require(MobileSSHIdentifiers.localID(of: second).flatMap(MobileSSHTmuxProvider.parseTerminalID)).pane
        Self.tmux("send-keys", "-t", "%\(pane)", "echo background-$((8*8))", "Enter")
        try await sink.waitForOutput(second) { $0.contains("background-64") }

        Self.tmux("split-window", "-d", "-t", "%\(pane)")
        try await Self.waitUntil {
            sink.states.last?.workspaces.first { $0.id == row.id }?.terminals.count == 3
        }
    }

    /// Plain shells have no terminal tabs; cmux-tui creates a terminal.
    @Test(.timeLimit(.minutes(2)), arguments: [SSHPersistenceMode.plain, .cmuxTUI])
    func newTerminalPerMode(mode: SSHPersistenceMode) async throws {
        let (computers, sink, host) = try await makeRuntime()
        defer { Task { @MainActor in await cleanup(computers, host: host) } }
        let answering = autoAnswer(computers, persistence: mode)
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        let scoped = try #require(await computers.createWorkspace(hostID: host.id))
        defer { Task { @MainActor in await computers.closeWorkspace(scopedID: scoped) } }
        let before = sink.states.last?.workspaces.first { $0.id.rawValue == scoped }?.terminals.count ?? 0
        let created = await computers.createTerminal(inWorkspace: scoped)
        if mode == .plain {
            #expect(!computers.supportsTerminalTabs(workspaceID: scoped))
            #expect(created == nil)
            return
        }
        #expect(computers.supportsTerminalTabs(workspaceID: scoped))
        let surface = try #require(created)
        let terminals = sink.states.last?.workspaces.first { $0.id.rawValue == scoped }?.terminals ?? []
        #expect(terminals.count == before + 1)
        #expect(terminals.contains { $0.id.rawValue == surface })
        computers.viewportChanged(surfaceID: surface, columns: 80, rows: 24)
        computers.replay(surfaceID: surface)
        try await sink.waitForOutput(surface) { !$0.isEmpty }
        computers.input(Data("echo tui-$((9*9))\r".utf8), surfaceID: surface)
        try await sink.waitForOutput(surface) { $0.contains("tui-81") }
    }

    /// Runs the lab's tmux directly (same user and server as the lab sshd).
    @discardableResult
    static func tmux(_ arguments: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func waitUntil(timeout: Duration = .seconds(15), _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for condition")
        throw CancellationError()
    }

    // MARK: Helpers

    func makeRuntime() async throws -> (MobileSSHComputers, RecordingSSHSink, SSHHostRecord) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-rt-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let sink = RecordingSSHSink()
        computers.sink = sink
        let key = try await computers.importKey(
            label: "lab",
            privateKeyText: try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8),
            passphrase: nil
        )
        let host = SSHHostRecord(
            name: "Lab",
            endpoint: SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()),
            keyID: key.id
        )
        try await computers.saveHost(host)
        return (computers, sink, host)
    }

    func autoAnswer(_ computers: MobileSSHComputers, persistence: SSHPersistenceMode) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                for prompt in computers.prompts {
                    switch prompt {
                    case .trustNewHostKey: computers.answer(prompt, with: .trust)
                    case .choosePersistence: computers.answer(prompt, with: .persistence(persistence))
                    case .hostKeyChanged: computers.answer(prompt, with: .cancel)
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func cleanup(_ computers: MobileSSHComputers, host: SSHHostRecord) async {
        for key in computers.keys { try? await computers.deleteKey(id: key.id) }
        try? await computers.deleteHost(id: host.id)
    }
}

@MainActor
final class RecordingSSHSink: MobileSSHComputersSink {
    var states: [MacWorkspaceState] = []
    var outputs: [String: String] = [:]

    func sshPublishWorkspaceState(_ state: MacWorkspaceState) { states.append(state) }
    func sshRemoveWorkspaceState(computerID: String) {}
    var viewportApplications: [String: Int] = [:]
    func sshDeliver(_ bytes: Data, surfaceID: String) {
        outputs[surfaceID, default: ""] += String(decoding: bytes, as: UTF8.self)
    }
    func sshApplyViewport(surfaceID: String) {
        viewportApplications[surfaceID, default: 0] += 1
    }
    func sshReplaceBrowserPanels(workspaceID: String, with descriptors: [MobileBrowserPanelDescriptor]) {}
    func sshDeliverBrowserFrame(_ event: MobileBrowserFrameEvent) {}
    func sshDeliverBrowserState(_ event: MobileBrowserStateEvent) {}
    func sshBrowserStreamEnded(panelID: String, retry: Bool) {}

    func waitForOutput(_ surfaceID: String, timeout: Duration = .seconds(15), until predicate: (String) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate(outputs[surfaceID] ?? "") { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out; output so far: \((outputs[surfaceID] ?? "").suffix(600))")
        throw CancellationError()
    }
}
