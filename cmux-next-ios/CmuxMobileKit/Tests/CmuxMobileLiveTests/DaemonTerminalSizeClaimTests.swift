import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A phone's size claim on a Mac terminal lasts only while the terminal is on
/// screen (cmux-next-ios/PROTOCOL.md, "Terminal size claims"): hidden, the
/// session releases it (`release-surface-size`) and sends no size; shown, it
/// claims its size again; stopped, it releases before its channel closes; and
/// while it claims, it refreshes the Mac's size lease (`size-lease-v1`).
@MainActor @Suite struct DaemonTerminalSizeClaimTests {
    private func session(_ daemon: FakeTerminalDaemon, channels: ChannelLog? = nil) -> DaemonTerminalSession {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        return DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            channels?.append(channel)
            return DaemonClient(channel: channel)
        }
    }

    private func commands(_ daemon: FakeTerminalDaemon, _ cmd: String) -> [[String: Any]] {
        daemon.recorded.filter { $0["cmd"] as? String == cmd }
    }

    @Test func aHiddenTerminalReleasesItsSize() async throws {
        let daemon = FakeTerminalDaemon()
        let session = session(daemon)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { commands(daemon, "resize-surface").count == 1 }

        session.setClaimsSize(false)
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }
        #expect(commands(daemon, "release-surface-size").first?["surface"] as? Int == 7)
        // Hidden twice: one release.
        session.setClaimsSize(false)
        try await settle()
        #expect(commands(daemon, "release-surface-size").count == 1)
    }

    @Test func aHiddenTerminalSendsNoSizeAndClaimsItWhenShown() async throws {
        let daemon = FakeTerminalDaemon()
        let session = session(daemon)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { commands(daemon, "resize-surface").count == 1 }
        session.setClaimsSize(false)
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }

        // A layout pass while hidden (rotation behind a sheet): not sent.
        session.resize(columns: 60, rows: 40)
        try await settle()
        #expect(commands(daemon, "resize-surface").count == 1)

        session.setClaimsSize(true)
        try await waitUntil { commands(daemon, "resize-surface").count == 2 }
        let claim = try #require(commands(daemon, "resize-surface").last)
        #expect(claim["cols"] as? Int == 60)
        #expect(claim["rows"] as? Int == 40)
    }

    @Test func aTerminalShownAgainClaimsTheSameSizeAgain() async throws {
        let daemon = FakeTerminalDaemon()
        let session = session(daemon)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { commands(daemon, "resize-surface").count == 1 }
        session.setClaimsSize(false)
        session.setClaimsSize(true)
        try await waitUntil { commands(daemon, "resize-surface").count == 2 }
        // Released, then claimed: in that order.
        let order = daemon.recorded.compactMap { $0["cmd"] as? String }.filter { $0 == "release-surface-size" || $0 == "resize-surface" }
        #expect(order == ["resize-surface", "release-surface-size", "resize-surface"])
    }

    @Test func stoppingReleasesTheSizeBeforeTheChannelCloses() async throws {
        let daemon = FakeTerminalDaemon()
        let session = session(daemon)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { commands(daemon, "resize-surface").count == 1 }
        session.stop()
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }
    }

    @Test func aHiddenTerminalReattachesWithoutASize() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        let channels = ChannelLog()
        let session = session(daemon, channels: channels)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { session.isAttached }
        session.setClaimsSize(false)
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }

        await channels.last?.close(code: "link_closed", reason: "link dropped")
        try await waitUntil { !session.isAttached }
        session.reconnect()
        try await waitUntil { session.isAttached }
        let reattach = try #require(commands(daemon, "attach-surface").last)
        #expect(reattach["cols"] == nil, "a hidden terminal's reattach claimed a size: \(reattach)")
        try await settle()
        #expect(commands(daemon, "resize-surface").count == 0)
    }

    /// Review finding: hidden while its sized attach was out, the attach's
    /// size was never released.
    @Test func aTerminalHiddenDuringItsAttachReleasesTheSizeTheAttachCarried() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.initialSize = true
        nonisolated(unsafe) var hide: (@MainActor @Sendable () -> Void)?
        let link = MockMacLink { service, line in
            // The page leaves while the sized attach is on its way to the Mac.
            if String(decoding: line, as: UTF8.self).contains("\"attach-surface\""), let run = hide {
                hide = nil
                if Thread.isMainThread { MainActor.assumeIsolated { run() } } else { DispatchQueue.main.sync { MainActor.assumeIsolated { run() } } }
            }
            return daemon.respond(service, line)
        }
        let session = DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
        hide = { session.setClaimsSize(false) }
        session.resize(columns: 54, rows: 42)
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let attach = try #require(commands(daemon, "attach-surface").first)
        #expect(attach["cols"] as? Int == 54, "the attach carried the size")
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }
        #expect(commands(daemon, "resize-surface").isEmpty)
    }

    @Test func theChannelOptsIntoTheSizeLease() async throws {
        let daemon = FakeTerminalDaemon()
        let session = session(daemon)
        session.start { _ in }
        try await waitUntil { session.isAttached }
        let info = try #require(commands(daemon, "set-client-info").first)
        #expect((info["capabilities"] as? [String])?.contains("size-lease-v1") == true)
        #expect(info["device_kind"] as? String == "iphone")
    }

    @Test func aShownTerminalRefreshesItsSizeLeaseAndAHiddenOneDoesNot() async throws {
        let daemon = FakeTerminalDaemon()
        daemon.sizeLease = true
        let session = session(daemon)
        session.sizeLeaseRefresh = .milliseconds(40)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { commands(daemon, "resize-surface").count >= 3 }
        #expect(commands(daemon, "resize-surface").allSatisfy { $0["cols"] as? Int == 54 && $0["rows"] as? Int == 42 })

        session.setClaimsSize(false)
        try await waitUntil { commands(daemon, "release-surface-size").count == 1 }
        let hidden = commands(daemon, "resize-surface").count
        try await Task.sleep(for: .milliseconds(200))
        #expect(commands(daemon, "resize-surface").count == hidden, "a hidden terminal refreshed its size")
    }

    @Test func aDaemonWithoutTheLeaseGetsNoRefresh() async throws {
        let daemon = FakeTerminalDaemon()
        let session = session(daemon)
        session.sizeLeaseRefresh = .milliseconds(40)
        session.start { _ in }
        session.resize(columns: 54, rows: 42)
        try await waitUntil { commands(daemon, "resize-surface").count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(commands(daemon, "resize-surface").count == 1)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    private func waitUntil(attempts: Int = 300, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<attempts where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
