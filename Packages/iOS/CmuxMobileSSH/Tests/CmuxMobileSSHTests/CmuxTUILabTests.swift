@testable import CmuxMobileSSH
import Foundation
import Testing

/// Live cmux-tui tests over the local sshd lab. Run with
/// `CMUX_SSH_LAB=/tmp/cmux-ssh-lab CMUX_TUI_BIN=/abs/path/cmux-tui swift test --filter CmuxTUI`.
/// Each test owns a unique session and removes its state afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil
    && ProcessInfo.processInfo.environment["CMUX_TUI_BIN"] != nil))
struct CmuxTUILabTests {
    let lab = ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] ?? ""
    let binary = ProcessInfo.processInfo.environment["CMUX_TUI_BIN"] ?? ""
    var endpoint: SSHEndpoint { SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()) }

    func connect() async throws -> SSHConnection {
        let text = try String(contentsOfFile: "\(lab)/client_ed25519", encoding: .utf8)
        return try await SSHConnection.connect(
            to: endpoint,
            credentials: [.privateKey(try SSHParsedPrivateKey(openSSH: text).key)],
            hostKeyVerifier: RecordingVerifier(accept: true)
        )
    }

    @Test func probeReportsInstalledBinaryAndPlatform() async throws {
        let ssh = try await connect()
        let probe = try await CmuxTUIRemote(binaryPath: binary).probe(on: ssh)
        #expect(probe.binaryPath == binary)
        #expect(probe.os == (try shell("uname -s")))
        #expect(probe.arch == (try shell("uname -m")))
        #expect(probe.npmPlatformPackage != nil)
        let installed = try #require(probe.installed)
        #expect(installed.version != nil)
        #expect(installed.distributionVersion != nil)

        let missing = try await CmuxTUIRemote(binaryPath: "~/.cmux-lab-missing/cmux-tui").probe(on: ssh)
        #expect(missing.installed == nil)
        #expect(missing.binaryPath.hasSuffix("/.cmux-lab-missing/cmux-tui"))
        #expect(!missing.binaryPath.hasPrefix("~"))
        await ssh.close()
    }

    @Test func connectFailsClearlyWithoutBinary() async throws {
        let ssh = try await connect()
        await #expect(throws: CmuxTUIError.self) {
            _ = try await CmuxTUIRemote(binaryPath: "/nonexistent/cmux-tui").connect(on: ssh, session: "cmux-lab-\(UUID().uuidString)")
        }
        await ssh.close()
    }

    /// PRD D13: the idle-close policy is sent only to servers that advertise
    /// `terminal-idle-close-v1`; older servers get nothing and report `false`.
    @Test(.timeLimit(.minutes(1))) func idlePolicyIsGatedOnTheServerCapability() async throws {
        let session = "cmux-lab-\(UUID().uuidString.lowercased())"
        defer { cleanUp(session: session) }
        let ssh = try await connect()
        let control = try await CmuxTUIRemote(binaryPath: binary).connect(on: ssh, session: session)
        let supported = await control.server.capabilities.contains(CmuxTUIControl.idleCloseCapability)
        let created = try await control.createWorkspace(name: "idle", cols: 80, rows: 24)
        let surface = try #require(created.terminal?.surface)
        #expect(try await control.setIdlePolicy(surface: surface, seconds: 3_600) == supported)
        #expect(try await control.setIdlePolicy(surface: surface, seconds: nil) == supported)
        await control.close()
        await ssh.close()
    }

    @Test(.timeLimit(.minutes(2))) func workspaceLifecyclePersistenceAndGeometry() async throws {
        let session = "cmux-lab-\(UUID().uuidString.lowercased())"
        let remote = CmuxTUIRemote(binaryPath: binary)
        defer { cleanUp(session: session) }

        // Connect (starts the headless owner) and create a workspace.
        var ssh = try await connect()
        var control = try await remote.connect(on: ssh, session: session)
        let info = await control.server
        #expect(info.app == "cmux-tui")
        #expect(info.protocolVersion >= CmuxTUIControl.minimumProtocol)
        #expect(info.session == session)

        let created = try await control.createWorkspace(name: "lab", cols: 80, rows: 24)
        let surface = try #require(created.terminal?.surface)
        var workspaces = try await control.listWorkspaces()
        let listed = try #require(workspaces.first { $0.key == created.key })
        #expect(listed.name == "lab")
        #expect(listed.terminals.map(\.surface) == [surface])
        #expect(listed.terminals.first?.resourceID?.hasPrefix("term_") == true)

        try await control.renameWorkspace(key: created.key, name: "lab-renamed")
        workspaces = try await control.listWorkspaces()
        #expect(workspaces.first { $0.key == created.key }?.name == "lab-renamed")

        // Attach, type, see output.
        var attachment = try await control.attach(surface: surface, cols: 80, rows: 24)
        var frames = attachment.events.makeAsyncIterator()
        guard case .vtState(_, 80, 24)? = await frames.next() else {
            Issue.record("first frame must be vt-state at the claimed size")
            return
        }
        try await attachment.write(Data("echo hi-$((1+1))\r".utf8))
        #expect(try await read(&frames, until: "hi-2"))

        // Detach, then reattach on the same connection: replay has the output.
        try await attachment.detach()
        while let frame = await frames.next() {
            #expect(frame != .exited, "detach must not report the terminal as exited")
        }
        attachment = try await control.attach(surface: surface, cols: 80, rows: 24)
        frames = attachment.events.makeAsyncIterator()
        #expect(replayText(await frames.next())?.contains("hi-2") == true)
        await control.close()
        await ssh.close()

        // A fresh SSH connection and relay still see the terminal (persistence).
        ssh = try await connect()
        control = try await remote.connect(on: ssh, session: session)
        workspaces = try await control.listWorkspaces()
        #expect(workspaces.contains { $0.key == created.key && $0.terminals.contains { $0.surface == surface } })
        attachment = try await control.attach(surface: surface, cols: 80, rows: 24)
        frames = attachment.events.makeAsyncIterator()
        #expect(replayText(await frames.next())?.contains("hi-2") == true)

        // Phone is geometry authority: resizing reshapes the PTY.
        let outcome = try await attachment.resize(cols: 100, rows: 30)
        #expect(outcome == .applied)
        #expect(try await readResized(&frames) == [100, 30])
        try await attachment.write(Data("stty size; echo sz-$((2+3))\r".utf8))
        let size = try await readText(&frames, until: "sz-5")
        #expect(size.contains("30 100"))

        // Titles and tree changes arrive on the subscription.
        let events = try await control.subscribe()
        let second = try await control.createTerminal(inWorkspace: created.key, cols: 80, rows: 24)
        var sawTreeChange = false
        for await event in events where event == .treeChanged {
            sawTreeChange = true
            break
        }
        #expect(sawTreeChange)
        try await attachment.write(Data("printf '\\033]2;lab-%s\\007' title; sleep 1\r".utf8))
        var sawTitle = false
        for await event in events {
            if event == .titleChanged(surface: surface, title: "lab-title") {
                sawTitle = true
                break
            }
        }
        #expect(sawTitle)

        // Closing the workspace also terminates its terminals.
        try await attachment.detach()
        try await control.closeWorkspace(key: created.key)
        workspaces = try await control.listWorkspaces()
        #expect(!workspaces.contains { $0.key == created.key })
        let alive = try await control.requestV2(
            "terminal.list",
            ["machine": .string(try await machineID(control)), "session": .string(try await sessionID(control))],
            as: [CmuxTUIResourceIDWire].self
        )
        #expect(alive.isEmpty, "terminals left running: \(alive.map(\.id)), second=\(second.terminalID)")
        await control.close()
        await ssh.close()
    }

    // MARK: - Helpers

    private func read(_ frames: inout AsyncStream<CmuxTUIAttachEvent>.Iterator, until marker: String) async throws -> Bool {
        try await readText(&frames, until: marker).contains(marker)
    }

    /// Accumulates output (and replays) until `marker` appears. The marker is
    /// computed in the shell so the PTY echo never contains it.
    private func readText(_ frames: inout AsyncStream<CmuxTUIAttachEvent>.Iterator, until marker: String) async throws -> String {
        var text = ""
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline, let frame = await frames.next() {
            switch frame {
            case .output(let data), .vtState(let data, _, _), .resized(_, _, let data):
                text += String(decoding: data, as: UTF8.self)
            case .exited, .disconnected:
                return text
            case .colors:
                break
            }
            if text.contains(marker) { return text }
        }
        return text
    }

    private func readResized(_ frames: inout AsyncStream<CmuxTUIAttachEvent>.Iterator) async throws -> [Int] {
        while let frame = await frames.next() {
            if case .resized(let cols, let rows, _) = frame { return [cols, rows] }
            if case .exited = frame { break }
        }
        return []
    }

    private func replayText(_ frame: CmuxTUIAttachEvent?) -> String? {
        guard case .vtState(let data, _, _)? = frame else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func machineID(_ control: CmuxTUIControl) async throws -> String {
        try await control.requestV2("machine.list", [:], as: [CmuxTUIResourceIDWire].self)[0].id
    }

    private func sessionID(_ control: CmuxTUIControl) async throws -> String {
        let sessions = try await control.requestV2("session.list", ["machine": .string(try await machineID(control))], as: [CmuxTUIResourceIDWire].self)
        return try #require(sessions.first { $0.name == control.session }).id
    }

    /// Stops the owner and removes the session's durable state and terminal hosts.
    private func cleanUp(session: String) {
        let quoted = session.posixShellSingleQuoted
        let bin = binary.posixShellSingleQuoted
        _ = try? shell("""
        \(bin) server stop --session \(quoted) --json >/dev/null 2>&1
        token=$(\(bin) session \(quoted) reset-state --json 2>/dev/null | sed -n 's/.*"confirm_reset":"\\([^"]*\\)".*/\\1/p')
        [ -n "$token" ] && \(bin) session \(quoted) reset-state --force --confirm-reset "$token" >/dev/null 2>&1
        true
        """)
    }
}
