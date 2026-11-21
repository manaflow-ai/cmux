import CmuxMobileTerminal
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// TEMPORARY diagnostics (never merged): how often a hide/show right after
/// the first claim puts the second claim before the release.
@MainActor @Suite(.serialized) struct FFDiagTests {
    private func session(_ daemon: FakeTerminalDaemon) -> DaemonTerminalSession {
        let link = MockMacLink { service, line in daemon.respond(service, line) }
        return DaemonTerminalSession(surface: 7, clientInfo: ["device_kind": "iphone"]) {
            DaemonClient(channel: try await link.openChannel(service: "daemon", args: [:]))
        }
    }

    private func cmds(_ daemon: FakeTerminalDaemon) -> [String] {
        daemon.recorded.compactMap { object -> String? in
            guard let cmd = object["cmd"] as? String else { return nil }
            if let cols = object["cols"] as? Int, let rows = object["rows"] as? Int { return "\(cmd):\(cols)x\(rows)" }
            return cmd
        }
    }

    private func resizes(_ daemon: FakeTerminalDaemon) -> Int {
        daemon.recorded.filter { $0["cmd"] as? String == "resize-surface" }.count
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func shownAgainOrder() async throws {
        var lines: [String] = []
        var bad = 0
        for index in 0..<30 {
            let daemon = FakeTerminalDaemon()
            let session = session(daemon)
            session.start { _ in }
            session.resize(columns: 54, rows: 42)
            try await wait { resizes(daemon) == 1 }
            let atHide = cmds(daemon)
            session.setClaimsSize(false)
            session.setClaimsSize(true)
            try await wait { resizes(daemon) == 2 }
            let atTwo = cmds(daemon)
            try await Task.sleep(for: .milliseconds(150))
            let all = cmds(daemon)
            let order = daemon.recorded.compactMap { $0["cmd"] as? String }.filter { $0 == "release-surface-size" || $0 == "resize-surface" }
            if Array(order.prefix(3)) != ["resize-surface", "release-surface-size", "resize-surface"] { bad += 1 }
            lines.append("\(index) atHide=\(atHide)\n  atTwo=\(atTwo)\n  all=\(all)")
            session.stop()
            try await Task.sleep(for: .milliseconds(20))
        }
        Attachment.record("bad=\(bad)/30\n" + lines.joined(separator: "\n"), named: "ffdiag-shown-again.txt")
    }
}
