@testable import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing

/// One lab host serving every kind at once (PRD D31), including primitives
/// created outside the phone: a tmux session and a cmux-tui workspace in a
/// separate cmux-tui session started the way a laptop starts one (its
/// socket in the user's macOS temporary directory). Run with
/// `CMUX_SSH_LAB=/tmp/cmux-ssh-lab`, tmux at `/opt/homebrew/bin/tmux`, and
/// cmux-tui at `~/.local/bin/cmux-tui`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct MobileSSHMixedKindsLabTests {
    static let cmuxTUI = NSString(string: "~/.local/bin/cmux-tui").expandingTildeInPath

    @Test(.timeLimit(.minutes(3))) func oneHostListsEveryKindAndDiscoversOutsidePrimitives() async throws {
        let lab = MobileSSHComputersLabTests()
        let suffix = UUID().uuidString.prefix(8).lowercased()

        // "Laptop" side: a tmux session and a cmux-tui workspace in another
        // cmux-tui session, neither created by the phone.
        let tmuxSession = "cmux-lab-mixed-\(suffix)"
        MobileSSHComputersLabTests.tmux("new-session", "-d", "-s", tmuxSession)
        defer { MobileSSHComputersLabTests.killSessionAndPhoneGroups(tmuxSession) }
        let laptopSession = "lab-laptop-\(suffix)"
        try Self.cmuxTUIShell("\"$B\" server ensure --session \(laptopSession) --json >/dev/null && \"$B\" --session \(laptopSession) workspace create --name laptop-ws --json >/dev/null")
        defer { Self.stopCmuxTUISession(laptopSession) }

        let (computers, sink, host) = try await lab.makeRuntime()
        defer { Task { @MainActor in await lab.cleanup(computers, host: host) } }
        let answering = lab.autoAnswer(computers)
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        #expect(computers.statusByHost[host.id] == .connected)
        #expect(computers.kindAvailability(hostID: host.id).allSatisfy { $0.isAvailable })

        // The phone adds a shell and a cmux-tui workspace (its own session).
        let shell = try #require(await computers.createWorkspace(hostID: host.id, kind: .shell))
        let own = try #require(await computers.createWorkspace(hostID: host.id, kind: .cmuxTUI))
        defer { Task { @MainActor in await computers.closeWorkspace(scopedID: own) } }

        let rows = try #require(sink.states.last?.workspaces)
        func row(_ id: String) -> MobileWorkspacePreview? { rows.first { $0.id.rawValue == id } }
        func local(_ row: MobileWorkspacePreview) -> MobileSSHLocalID? { MobileSSHLocalID(scopedID: row.id.rawValue) }

        let tmuxRow = try #require(rows.first { local($0) == .tmux(tmuxSession) })
        #expect(tmuxRow.previewText == "tmux session")
        let laptopRow = try #require(rows.first {
            if case .cmuxTUI(laptopSession, _) = local($0) { return true }
            return false
        })
        #expect(laptopRow.name == "laptop-ws")
        #expect(laptopRow.previewText == "cmux-tui · \(laptopSession)")
        #expect(row(own)?.previewText == "cmux-tui")
        guard case .cmuxTUI(let ownSession, _) = MobileSSHLocalID(scopedID: own) else {
            Issue.record("own workspace id is not cmux-tui: \(own)")
            return
        }
        #expect(ownSession == MobileSSHCmuxTUIProvider.sessionName)
        #expect(row(shell)?.previewText == "Shell")
        #expect(computers.kind(ofScopedID: shell) == .shell)

        // The laptop's cmux-tui workspace attaches through its existing
        // socket (never started by the phone), and typing reaches it.
        let laptopTerminal = try #require(laptopRow.terminals.first).id.rawValue
        computers.viewportChanged(surfaceID: laptopTerminal, columns: 70, rows: 20)
        computers.replay(surfaceID: laptopTerminal)
        try await sink.waitForOutput(laptopTerminal) { !$0.isEmpty }
        computers.input(Data("stty size; echo laptop-$((5*5))\r".utf8), surfaceID: laptopTerminal)
        try await sink.waitForOutput(laptopTerminal) { $0.contains("laptop-25") && $0.contains("20 70") }
        #expect(computers.tabLayout(workspaceID: laptopRow.id.rawValue)?.sections.count == 1)

        // Leaving the screen releases geometry; returning claims it again
        // and the phone's grid applies to the shared terminal.
        computers.viewportReleased(surfaceID: laptopTerminal)
        computers.viewportChanged(surfaceID: laptopTerminal, columns: 60, rows: 18)
        var reclaimed = false
        for _ in 0..<30 where !reclaimed {
            computers.input(Data("stty size\r".utf8), surfaceID: laptopTerminal)
            try await Task.sleep(for: .milliseconds(300))
            reclaimed = (sink.outputs[laptopTerminal] ?? "").contains("18 60")
        }
        #expect(reclaimed)

        // Attaching the tmux session goes through the phone's grouped
        // session, which never lists as a row of its own.
        let tmuxTerminal = try #require(tmuxRow.terminals.first).id.rawValue
        computers.viewportChanged(surfaceID: tmuxTerminal, columns: 80, rows: 24)
        computers.replay(surfaceID: tmuxTerminal)
        try await sink.waitForOutput(tmuxTerminal) { !MobileSSHComputersLabTests.afterLastReset($0).isEmpty }
        await computers.refreshWorkspaces(hostID: host.id)
        let relisted = try #require(sink.states.last?.workspaces)
        #expect(!relisted.contains { $0.name.contains(MobileSSHTmuxControlClient.groupedSessionMarker) })
        #expect(relisted.contains { $0.id == tmuxRow.id })
        #expect(relisted.contains { $0.id == laptopRow.id })

        await computers.closeWorkspace(scopedID: shell)
        #expect(sink.states.last?.workspaces.contains { $0.id.rawValue == shell } == false)
        await computers.closeWorkspace(scopedID: own)
        #expect(sink.states.last?.workspaces.contains { $0.id.rawValue == own } == false)
    }

    // MARK: Helpers

    /// Runs `script` locally with `$B` set to the lab's cmux-tui, from the
    /// test process's own environment (a laptop-like `TMPDIR`).
    @discardableResult
    static func cmuxTUIShell(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "B=\(cmuxTUI.posixShellSingleQuoted); " + script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "cmux-tui script failed: \(script)"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Closes the session's terminals, stops its owner, and removes its
    /// saved state (the same teardown the cmux-tui lab tests use).
    static func stopCmuxTUISession(_ session: String) {
        _ = try? cmuxTUIShell("""
        S=\(session.posixShellSingleQuoted)
        for t in $("$B" --session "$S" terminal list --json 2>/dev/null | grep -o '"id":"term_[0-9a-f]*"' | cut -d'"' -f4); do
          "$B" --session "$S" terminal "$t" close --json >/dev/null 2>&1
        done
        "$B" server stop --session "$S" --json >/dev/null 2>&1
        token=$("$B" session "$S" reset-state --json 2>/dev/null | sed -n 's/.*"confirm_reset":"\\([^"]*\\)".*/\\1/p')
        [ -n "$token" ] && "$B" session "$S" reset-state --force --confirm-reset "$token" >/dev/null 2>&1
        rm -f "$(getconf DARWIN_USER_TEMP_DIR)cmux-tui-$(id -u)/$S.sock.spawn-lock" "${TMPDIR:-/tmp}/cmux-tui-$(id -u)/$S.sock.spawn-lock"
        true
        """)
    }
}
