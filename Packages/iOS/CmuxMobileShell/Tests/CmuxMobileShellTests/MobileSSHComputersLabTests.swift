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
        // tmux reserves one row for its status line.
        try await sink.waitForOutput(surface) { $0.contains("ssh-42") && $0.contains(mode == .tmux ? "29 90" : "30 90") }

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

    // MARK: Helpers

    private func makeRuntime() async throws -> (MobileSSHComputers, RecordingSSHSink, SSHHostRecord) {
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

    private func autoAnswer(_ computers: MobileSSHComputers, persistence: SSHPersistenceMode) -> Task<Void, Never> {
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

    private func cleanup(_ computers: MobileSSHComputers, host: SSHHostRecord) async {
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
    func sshDeliver(_ bytes: Data, surfaceID: String) {
        outputs[surfaceID, default: ""] += String(decoding: bytes, as: UTF8.self)
    }

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
