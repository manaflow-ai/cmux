@testable import CmuxMobileShell
import CmuxMobileSSH
import Foundation
import Testing

/// v4 pty-live finding: when the tmux SERVER ends, its control-mode exec
/// channel closes while the SSH connection stays up, and sessions on the
/// next server never appeared until a manual pull-to-refresh. An
/// unexpectedly dead control client on a live host means the server (or
/// this session) went away: the provider must ask for one relist right
/// then (event-driven, no timers) and forget the per-server grouped-session
/// collection pass so the next listing re-collects on the new server. A
/// close the phone asked for, and a death during connection teardown,
/// stay silent.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MobileSSHTmuxServerRestartTests {
    private func makeProvider(
        hostIsOpen: @escaping () -> Bool
    ) -> (MobileSSHTmuxProvider, MobileSSHTmuxSeedOrderTests.Pipe, MobileSSHTmuxControlClient) {
        let provider = MobileSSHTmuxProvider(connection: nil, tmuxPath: "/usr/bin/tmux")
        provider.hostConnectionIsOpen = hostIsOpen
        let pipe = MobileSSHTmuxSeedOrderTests.Pipe()
        let control = MobileSSHTmuxControlClient(
            sessionName: "work",
            groupedSessionName: "work-cmux-ios-test",
            channel: pipe
        )
        control.startPump()
        provider.adopt(control, session: "work")
        return (provider, pipe, control)
    }

    @Test func serverDeathOnALiveHostAsksForOneRelistAndForgetsTheCollectionPass() async throws {
        let (provider, pipe, control) = makeProvider(hostIsOpen: { true })
        await provider.collectStaleGroupedSessions()
        #expect(provider.hasCachedCollectionPassForTesting)
        var relists = 0
        provider.onTopologyChange = { relists += 1 }

        await pipe.close() // the exec channel died with the server
        await control.awaitPumpEndForTesting()

        #expect(relists == 1)
        #expect(!provider.hasCachedCollectionPassForTesting)
        #expect(provider.groupedSessionName(for: "work") == nil)
    }

    @Test func phoneInitiatedCloseStaysSilent() async throws {
        let (provider, pipe, control) = makeProvider(hostIsOpen: { true })
        var relists = 0
        provider.onTopologyChange = { relists += 1 }

        let close = Task { try await provider.closeWorkspace(id: "work") }
        // The grouped-session kill awaits its tmux reply before the
        // channel closes; answer it once it reaches the wire.
        var writes = pipe.written.makeAsyncIterator()
        let written = try #require(await writes.next())
        #expect(String(decoding: written, as: UTF8.self).contains("kill-session"))
        pipe.tmux("%begin 1 1 1\n%end 1 1 1\n")
        try await close.value
        await control.awaitPumpEndForTesting()

        #expect(control.isClosed)
        #expect(relists == 0)
    }

    @Test func controlDeathDuringConnectionTeardownStaysSilent() async throws {
        let (provider, pipe, control) = makeProvider(hostIsOpen: { false })
        await provider.collectStaleGroupedSessions()
        var relists = 0
        provider.onTopologyChange = { relists += 1 }

        await pipe.close()
        await control.awaitPumpEndForTesting()

        #expect(relists == 0)
        #expect(provider.groupedSessionName(for: "work") == nil)
    }
}
