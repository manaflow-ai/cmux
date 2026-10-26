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

}
