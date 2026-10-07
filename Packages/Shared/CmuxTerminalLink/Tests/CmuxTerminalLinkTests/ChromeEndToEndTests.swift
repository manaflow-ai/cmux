import CmuxLink
import CmuxLinkTesting
import CmuxMobileHost
import CmuxTerminalLink
import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation
import Testing

/// D1's chrome over a real `MobileHost`: the connection banner's states and
/// scrollback on demand (d1-terminal-ux.md section 3).
@Suite("terminal chrome end to end")
struct ChromeEndToEndTests {
    static func waitFor<T: Sendable & Equatable>(_ stream: AsyncStream<T>, _ value: T) async throws {
        try await within {
            for await next in stream where next == value { return }
            throw TimeoutError()
        }
    }

    @Test func olderHistoryLoadsBeforeTheOldestPage() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 1000)
        attachment.history(offset: 500)
        _ = try await log.frame(.snapshotHistory)
        let states = await h.source.historyStates()
        await h.source.loadOlderHistory()
        try await TerminalLinkEndToEndTests.waitFor(attachment, "terminal.history")
        attachment.history(offset: 200)
        try await Self.waitFor(states, .loaded)
    }

    @Test func aHostWithoutPagedHistorySaysSoOnce() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        await attachment.setRefusesHistory(true)
        attachment.ready(offset: 1000)
        _ = try await log.frame(.snapshotReady)
        let states = await h.source.historyStates()
        await h.source.loadOlderHistory()
        try await Self.waitFor(states, .unavailable)
    }

    @Test func theBannerFollowsADropAndTheResume() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 1000)
        _ = try await log.frame(.snapshotReady)
        let states = await h.source.connectionStates()
        try await Self.waitFor(states, .connected)
        await h.network.dropAll()
        try await within {
            var sawReconnect = false
            for await state in states {
                if case .reconnecting = state { sawReconnect = true }
                if sawReconnect, state == .connected { return }
            }
            throw TimeoutError()
        }
    }

    @Test func linkStatesMapToBannerStates() {
        #expect(LinkTerminalByteSource.connectionState(.idle) == .connecting)
        #expect(LinkTerminalByteSource.connectionState(.connected(LinkPath(kind: .direct, carrier: .direct))) == .connected)
        #expect(LinkTerminalByteSource.connectionState(.reconnecting(attempt: 2, lastPath: nil)) == .reconnecting(attempt: 2))
        #expect(LinkTerminalByteSource.connectionState(.closed(.unreachable(attempts: 8))) == .offline)
    }
}
