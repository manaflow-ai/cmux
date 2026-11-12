@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

/// A reattach that lands while a full-screen program owns the terminal gets
/// a `vt-state` of the alternate screen only. When that program exits, the
/// phone must fetch a fresh snapshot so the primary screen and its history
/// come back. Run with `CMUX_SSH_LAB=/tmp/cmux-ssh-lab` and cmux-tui at
/// `~/.local/bin/cmux-tui`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_SSH_LAB"] != nil))
struct MobileSSHCmuxTUIAltScreenLabTests {
    @Test(.timeLimit(.minutes(2))) func leavingAlternateScreenAfterReattachRestoresHistory() async throws {
        let lab = MobileSSHComputersLabTests()
        let (computers, sink, host) = try await lab.makeRuntime()
        defer { Task { @MainActor in await lab.cleanup(computers, host: host) } }
        let answering = lab.autoAnswer(computers)
        defer { answering.cancel() }
        await computers.open(hostID: host.id)
        let scoped = try #require(await computers.createWorkspace(hostID: host.id, kind: .cmuxTUI))
        defer { Task { @MainActor in await computers.closeWorkspace(scopedID: scoped) } }
        let surface = try #require(sink.states.last?.workspaces.first { $0.id.rawValue == scoped }?.terminals.first).id.rawValue

        computers.viewportChanged(surfaceID: surface, columns: 80, rows: 10)
        computers.replay(surfaceID: surface)
        try await sink.waitForOutput(surface) { !$0.isEmpty }
        computers.input(Data("for i in $(seq 1 100); do echo early-$i; done\r".utf8), surfaceID: surface)
        try await sink.waitForOutput(surface) { $0.contains("early-100\r\n") }
        computers.input(Data("seq 5001 5100 | less\r".utf8), surfaceID: surface)
        try await sink.waitForOutput(surface) { $0.contains("\u{1B}[?1049h") && $0.contains("5003") }

        // Reattach while less owns the alternate screen.
        await computers.disconnect(hostID: host.id)
        sink.outputs[surface] = ""
        await computers.open(hostID: host.id)
        computers.replay(surfaceID: surface)
        try await sink.waitForOutput(surface) { Self.afterLastReset($0).contains("5003") }
        let altSnapshot = Self.afterLastReset(sink.outputs[surface] ?? "")
        #expect(altSnapshot.contains("\u{1B}[?1049h"))
        #expect(!altSnapshot.contains("early-3\r\n"), "the alternate-screen snapshot has no primary history")

        // Quit less: the phone resyncs and the fresh primary snapshot carries
        // lines that scrolled off the 10-row screen long before.
        computers.input(Data("q".utf8), surfaceID: surface)
        try await sink.waitForOutput(surface) { Self.afterLastReset($0).contains("early-3\r\n") }
        let restored = Self.afterLastReset(sink.outputs[surface] ?? "")
        #expect(restored.contains("early-100\r\n"))
        #expect(!restored.contains("\u{1B}[?1049h"))

        // The resynced stream stays live.
        computers.input(Data("echo after-$((6*7))\r".utf8), surfaceID: surface)
        try await sink.waitForOutput(surface) { Self.afterLastReset($0).contains("after-42") }
        await computers.closeWorkspace(scopedID: scoped)
    }

    /// The text after the last full reset (RIS) the runtime sent.
    static func afterLastReset(_ output: String) -> String {
        guard let range = output.range(of: "\u{1B}c", options: .backwards) else { return output }
        return String(output[range.upperBound...])
    }
}
