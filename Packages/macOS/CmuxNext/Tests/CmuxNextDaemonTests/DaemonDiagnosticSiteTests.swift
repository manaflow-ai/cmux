import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The daemon's `server-diagnostic-site` events on the app side: the line decodes to a
/// path-free site and anything else is refused; the relay holds the sites read before its sink exists,
/// hands each site to it once (a daemon replays its sites on every subscribe), and only the connection
/// that reports them asks the daemon for them.
struct DaemonDiagnosticSiteTests {
    private static func decode(_ json: String) throws -> DaemonDiagnosticSite {
        try JSONDecoder().decode(DaemonDiagnosticSite.self, from: Data(json.utf8))
    }

    private static let fsLine = #"{"event":"server-diagnostic-site","family":"blocking","kind":"fs","crate":"cmux-tui-core","file_hash":"9f2c4e1a7b3d5c60","line":412,"lane_sync":false,"cause":"frontend"}"#

    @Test func anEventLineDecodesToItsSite() throws {
        let site = try Self.decode(Self.fsLine)
        #expect(site.family == .blocking)
        #expect(site.kind == "fs")
        #expect(site.crateName == "cmux-tui-core")
        #expect(site.line == 412)
        #expect(site.key == "daemon-cmux-tui-core-9f2c4e1a7b3d5c60-412")
        let hang = try Self.decode(#"{"event":"server-diagnostic-site","family":"hang","kind":"request","method":"frame.apps"}"#)
        #expect(hang.key == "daemon-hang-frame.apps")
        // A holder-link frame and a journal commit past their hang tiers: their scope is part of the site.
        let holder = try Self.decode(#"{"event":"server-diagnostic-site","family":"hang","kind":"holder-link","method":"data"}"#)
        #expect(holder.key == "daemon-hang-holder-link-data")
        let journal = try Self.decode(#"{"family":"hang","kind":"journal-writer","method":"commit-batch"}"#)
        #expect(journal.key == "daemon-hang-journal-writer-commit-batch")
    }

    @Test func aLineThatCouldCarryAPathOrTextIsRefused() {
        let refused = [
            #"{"family":"blocking","kind":"fs","crate":"/Users/alice/src","file_hash":"9f2c4e1a7b3d5c60","line":1}"#,
            #"{"family":"blocking","kind":"fs","crate":"cmux","file_hash":"/Users/alice/x.rs","line":1}"#,
            #"{"family":"blocking","kind":"Alice Liddell","crate":"cmux","file_hash":"9f2c4e1a7b3d5c60","line":1}"#,
            #"{"family":"hang","kind":"request","method":"frame:apps"}"#,
            #"{"family":"blocking","kind":"fs","crate":"cmux","line":1}"#,
            #"{"family":"hang","kind":"request"}"#,
            #"{"family":"crash","kind":"fs","crate":"cmux","file_hash":"9f2c4e1a7b3d5c60","line":1}"#,
        ]
        for line in refused {
            #expect(throws: DecodingError.self, "\(line)") { try Self.decode(line) }
        }
    }

    @Test func theRelayHoldsSitesUntilItsSinkThenHandsEachSiteOnce() throws {
        let relay = DaemonDiagnosticSiteRelay<DaemonDiagnosticSite>()
        let first = try Self.decode(Self.fsLine)
        let hang = try DaemonDiagnosticSite(family: .hang, kind: "request", method: "list-workspaces")
        relay.deliver(first)
        relay.deliver(first)
        let received = Mutex<[String]>([])
        relay.install { site in received.withLock { $0.append(site.key) } }
        #expect(received.withLock { $0 } == [first.key])

        // A replay after a reconnect, and the same site under another kind, add nothing.
        relay.deliver(first)
        relay.deliver(try DaemonDiagnosticSite(family: .blocking, kind: "sleep", crateName: "cmux-tui-core",
                                               fileHash: "9f2c4e1a7b3d5c60", line: 412))
        relay.deliver(hang)
        #expect(received.withLock { $0 } == [first.key, hang.key])
    }

    @Test func onlyAReportingConnectionAsksTheDaemonForItsSites() {
        var configuration = DaemonConnectionConfiguration(terminalEnvironment: nil)
        let capability = DaemonCapability.diagnosticSites.rawValue
        #expect(!DaemonCapability.advertised.contains(capability))
        #expect(!configuration.handshakeCapabilities.contains(capability))
        configuration.reportsDiagnosticSites = true
        #expect(configuration.handshakeCapabilities.filter { $0 == capability }.count == 1)
        #expect(DaemonCapability.diagnosticSites.tier == .optional)
    }
}
