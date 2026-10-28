@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileSSHTmuxOpeningTests {
    private func client(_ suffix: String) -> MobileSSHTmuxControlClient {
        let control = MobileSSHTmuxControlClient(
            sessionName: "work",
            groupedSessionName: "work-cmux-ios-" + suffix,
            channel: MobileSSHTmuxOpeningTransport()
        )
        control.startPump()
        return control
    }

    private func attach(_ provider: MobileSSHTmuxProvider, pane: Int = 1) async throws -> any MobileSSHAttachedTerminal {
        try await provider.attach(terminalID: "work/%\(pane)", columns: 80, rows: 24) { _ in }
    }

    @Test func concurrentAttachesShareOneOpening() async throws {
        let gate = MobileSSHTmuxOpeningGate()
        let provider = MobileSSHTmuxProvider(connection: nil, tmuxPath: "/usr/bin/tmux", controlOpener: gate.open)
        var attempts = gate.attempts.makeAsyncIterator()
        let first = Task { _ = try await attach(provider, pane: 1) }
        let attempt = try #require(await attempts.next())
        let second = Task { _ = try await attach(provider, pane: 2) }

        let current = client("current")
        attempt.completion.resume(returning: current)
        try await first.value
        try await second.value

        #expect(gate.count == 1)
        #expect(current.attachedPaneCount == 2)
        try await provider.closeWorkspace(id: "work")
    }

    @Test func closeRejectsAndClosesALateOpen() async throws {
        let gate = MobileSSHTmuxOpeningGate()
        let provider = MobileSSHTmuxProvider(connection: nil, tmuxPath: "/usr/bin/tmux", controlOpener: gate.open)
        var attempts = gate.attempts.makeAsyncIterator()
        let pending = Task { _ = try await attach(provider) }
        let attempt = try #require(await attempts.next())
        #expect(attempt.session == "work")

        try await provider.closeWorkspace(id: "work")
        let stale = client("stale")
        attempt.completion.resume(returning: stale)
        let result = await pending.result

        if case .failure(let error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("An open that completed after workspace close attached a pane")
        }
        #expect(stale.isClosed)
        #expect(stale.attachedPaneCount == 0)
        #expect(provider.groupedSessionName(for: "work") == nil)
        await stale.close()
    }

    @Test func canceledOpenResolvesItsContinuationAndClosesTheChannel() async throws {
        let transport = MobileSSHTmuxOpeningTransport(respondToWrites: false)
        let pending = Task {
            try await MobileSSHTmuxControlClient.open(
                session: "work",
                groupedSessionName: "work-cmux-ios-stalled",
                channel: transport
            )
        }
        var writes = transport.writes.makeAsyncIterator()
        _ = try #require(await writes.next())

        pending.cancel()
        let result = await pending.result
        if case .success = result { Issue.record("A canceled open completed successfully") }
        #expect(transport.didAbort)
    }

    @Test func abortingAStalledCommandResolvesItsContinuationAndClosesTheChannel() async throws {
        let transport = MobileSSHTmuxOpeningTransport(respondToWrites: false)
        let client = MobileSSHTmuxControlClient(
            sessionName: "work",
            groupedSessionName: "work-cmux-ios-stalled",
            channel: transport
        )
        client.startPump()
        let pending = Task { try await client.command("list-panes") }
        var writes = transport.writes.makeAsyncIterator()
        _ = try #require(await writes.next())

        client.abort()
        let cleanup = try #require(await writes.next())
        #expect(String(decoding: cleanup, as: UTF8.self).contains("kill-session"))
        let result = await pending.result
        if case .success = result { Issue.record("A stalled command completed after abort") }
        #expect(client.isClosed)
    }

    @Test(arguments: [false, true])
    func staleCompletionDoesNotEraseOrReplaceANewerOpen(fails: Bool) async throws {
        let gate = MobileSSHTmuxOpeningGate()
        let provider = MobileSSHTmuxProvider(connection: nil, tmuxPath: "/usr/bin/tmux", controlOpener: gate.open)
        var attempts = gate.attempts.makeAsyncIterator()
        let first = Task { _ = try await attach(provider) }
        let firstAttempt = try #require(await attempts.next())
        try await provider.closeWorkspace(id: "work")

        let replacement = Task { _ = try await attach(provider, pane: 2) }
        // The old operation is deliberately still suspended when the replacement starts.
        let secondAttempt = try #require(await attempts.next())
        let replacementID = try #require(provider.opening["work"]?.id)
        let stale = client("stale")
        if fails {
            firstAttempt.completion.resume(throwing: SSHConnectionError.closed)
        } else {
            firstAttempt.completion.resume(returning: stale)
        }
        let firstResult = await first.result
        if case .success = firstResult { Issue.record("The invalidated open succeeded") }

        #expect(provider.opening["work"]?.id == replacementID)
        let current = client("current")
        secondAttempt.completion.resume(returning: current)
        try await replacement.value
        let another = try await attach(provider, pane: 3)
        #expect(gate.count == 2)
        #expect(provider.groupedSessionName(for: "work") == current.groupedSessionName)
        #expect(current.attachedPaneCount == 2)
        if !fails { #expect(stale.isClosed) }
        await another.detach()
        try await provider.closeWorkspace(id: "work")
        await stale.close()
    }

    @Test func staleCompletionAfterReplacementAdoptionCannotOverwriteCurrent() async throws {
        let gate = MobileSSHTmuxOpeningGate()
        let provider = MobileSSHTmuxProvider(connection: nil, tmuxPath: "/usr/bin/tmux", controlOpener: gate.open)
        var attempts = gate.attempts.makeAsyncIterator()
        let first = Task { _ = try await attach(provider, pane: 1) }
        let firstAttempt = try #require(await attempts.next())
        try await provider.closeWorkspace(id: "work")

        let replacement = Task { _ = try await attach(provider, pane: 2) }
        let secondAttempt = try #require(await attempts.next())
        let current = client("current")
        secondAttempt.completion.resume(returning: current)
        try await replacement.value

        let stale = client("stale")
        firstAttempt.completion.resume(returning: stale)
        let firstResult = await first.result
        if case .success = firstResult { Issue.record("The invalidated open succeeded") }

        #expect(provider.groupedSessionName(for: "work") == current.groupedSessionName)
        #expect(current.attachedPaneCount == 1)
        #expect(stale.isClosed)
        try await provider.closeWorkspace(id: "work")
    }
}
