import CmuxNextCompat
@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
@testable import CmuxNextHangReports
import Foundation
import Testing

/// The daemon's `server-diagnostic-site` events end to end on the app side: a scripted daemon
/// on the real JSON-lines transport sends its sites, a duplicate and a holder-link hang to a connection that
/// reports them; they pass the connection's reader, its relay and the service's relay (``DaemonDiagnosticSiteRelay/forward(to:)``,
/// as `DaemonService.didConnect` wires it) into the app's ``BlockingReportSink`` and its collector. Each site is
/// one `.daemon` sample; a reconnect to the same daemon life and a relaunch against it (a new service relay and
/// sink over the same saved state) add none. A connection that does not report sites does not ask for them and
/// decodes such a line as any other event.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DaemonDiagnosticSitePathTests {
    private struct Done: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "test-sites-done"
    }

    /// One boot of a daemon: the same pid and generation on every connection. It sends its sites after
    /// `subscribe` only to a connection that echoed `diagnostic-sites-v1`, unless started with `always`.
    private static let script = #"""
    import json, sys
    always = sys.argv[1] == 'always'
    print('{"ok":true}', file=sys.stderr, flush=True)
    asked = False
    def send(value):
        print(json.dumps(value), flush=True)
    def reply(frame, data):
        send({'id': frame.get('id'), 'ok': True, 'data': data})
    site = {'event': 'server-diagnostic-site', 'family': 'blocking', 'kind': 'fs', 'crate': 'cmux-tui-core',
            'file_hash': '9f2c4e1a7b3d5c60', 'line': 412, 'lane_sync': False}
    sites = [site, dict(site, kind='sleep'),
             {'event': 'server-diagnostic-site', 'family': 'hang', 'kind': 'request', 'method': 'frame.apps'},
             {'event': 'server-diagnostic-site', 'family': 'hang', 'kind': 'holder-link', 'method': 'data'},
             site]
    for line in sys.stdin:
        frame = json.loads(line)
        command = frame.get('cmd')
        if command == 'identify':
            reply(frame, {'app': 'cmux-tui', 'protocol': 12, 'session': 'sites', 'pid': 4242,
                          'generation': '0b6f5c1e-2d1a-4c3b-9e8f-7a6b5c4d3e2f', 'capabilities': ['diagnostic-sites-v1']})
        elif command == 'set-client-info':
            asked = 'diagnostic-sites-v1' in (frame.get('capabilities') or [])
            reply(frame, {})
        elif command == 'subscribe':
            reply(frame, {})
            if asked or always:
                for value in sites:
                    send(value)
        elif command == 'test-sites-done':
            reply(frame, {'asked': asked})
        else:
            reply(frame, {})
    """#

    /// What one install keeps across launches: the daemon-site ledger and the last-sent times.
    private final class SavedState: Sendable {
        private let ledger = Mutex(DaemonSiteLedger())
        private let times = Mutex<[String: Date]>([:])
        private let daemonTimes = Mutex<[String: Date]>([:])

        var ledgerStore: DaemonSiteLedger.Store {
            .init(load: { self.ledger.withLock { $0 } }, save: { saved in self.ledger.withLock { $0 = saved } })
        }

        var store: BlockingReportSink.LastSentStore {
            .init(load: { self.times.withLock { $0 } }, save: { saved in self.times.withLock { $0 = saved } })
        }

        var daemonStore: BlockingReportSink.LastSentStore {
            .init(load: { self.daemonTimes.withLock { $0 } }, save: { saved in self.daemonTimes.withLock { $0 = saved } })
        }
    }

    /// One app launch: the service's relay feeding a sink over `saved`, as `WatchdogReporting` installs it (the
    /// app runs each record on a lane; here it runs inline).
    private final class Launch: Sendable {
        let service = DaemonDiagnosticSiteRelay<DaemonDiagnosticSite.Sighting>()
        let collector = HangReportCollector(resolve: { _ in [] }, resolveBlocking: { $0.map { _ in .other } }, schedule: { $0() })
        private let sends = Mutex<[BlockingReportSink.NonFatalEvent]>([])

        var sent: [BlockingReportSink.NonFatalEvent] { sends.withLock { $0 } }
        var daemonSites: [String] { collector.snapshot().blocking.filter { $0.source == .daemon }.compactMap(\.daemon?.site) }

        init(_ saved: SavedState) {
            collector.setEnabled(true)
            let sink = BlockingReportSink(
                collector: collector,
                nonFatal: .init(consented: { true }, send: { [weak self] event in self?.sends.withLock { $0.append(event) } }),
                store: saved.store, daemonStore: saved.daemonStore, daemonSites: saved.ledgerStore)
            service.install { sink.record(daemonSite: $0) }
        }

        /// Connects one reporting connection to a new process of the scripted daemon, forwarded into the
        /// service's relay, and returns it once every line the daemon sent after `subscribe` was read.
        func connect() async throws -> DaemonConnection {
            let connection = DaemonDiagnosticSitePathTests.connection(reportsSites: true)
            connection.diagnosticSites.forward(to: service)
            try await connection.start()
            let done = try await connection.request(Done())
            #expect(done["asked"]?.boolValue == true, "the reporting connection did not echo diagnostic-sites-v1")
            return connection
        }
    }

    private static func connection(reportsSites: Bool, always: Bool = false) -> DaemonConnection {
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, always ? "always" : "asked"])
        var configuration = DaemonConnection.Configuration(requiredCapabilities: [], requestTimeout: .seconds(2), terminalEnvironment: nil)
        configuration.reportsDiagnosticSites = reportsSites
        return DaemonConnection(endpoint: .init(socketPath: "/tmp/cmux-sites-test-\(UUID().uuidString).sock", bridge: bridge),
                                configuration: configuration)
    }

    private static let expectedSites = [
        "daemon-cmux-tui-core-9f2c4e1a7b3d5c60-412", "daemon-hang-frame.apps", "daemon-hang-holder-link-data",
    ]

    @Test func theAppsLocalConnectionReportsSites() {
        let local = DaemonService.localConfiguration(terminalEnvironment: nil, resolvesShellIntegration: false,
                                                     installKey: nil, echoesPlacementShift: false)
        #expect(local.reportsDiagnosticSites)
        #expect(local.handshakeCapabilities.contains(DaemonCapability.diagnosticSites.rawValue))
    }

    @Test func eachSiteOfOneDaemonLifeIsOneDaemonSampleAcrossReconnectsAndRelaunches() async throws {
        let saved = SavedState()
        let first = Launch(saved)
        let connection = try await first.connect()
        #expect(first.daemonSites == Self.expectedSites)
        #expect(first.sent.map(\.type) == ["DaemonBlocking", "DaemonHang", "DaemonHang"])

        // The reporting connection routes each site line on with no payload.
        var routed = 0
        for try await envelope in connection.events {
            guard case .unknown(let name, let payload) = envelope.event, name == DaemonDiagnosticSite.eventName else { continue }
            #expect(payload == .null)
            routed += 1
            if routed == 5 { break }
        }
        await connection.close()

        // A reconnect to the same daemon life: the daemon replays every site; nothing is new.
        let again = try await first.connect()
        await again.close()
        #expect(first.daemonSites == Self.expectedSites)
        #expect(first.sent.count == 3)

        // The next app launch against the same daemon: a new relay, sink and collector over the saved state.
        let relaunch = Launch(saved)
        let third = try await relaunch.connect()
        await third.close()
        #expect(relaunch.daemonSites.isEmpty)
        #expect(relaunch.sent.isEmpty)
    }

    @Test func aConnectionThatDoesNotReportSitesNeitherAsksNorRelaysThem() async throws {
        let quiet = Self.connection(reportsSites: false)
        let relayed = Mutex(0)
        quiet.diagnosticSites.install { _ in relayed.withLock { $0 += 1 } }
        try await quiet.start()
        #expect(try await quiet.request(Done())["asked"]?.boolValue == false)
        await quiet.close()
        #expect(relayed.withLock { $0 } == 0)

        // A daemon that sends them anyway: the line decodes as any unknown event, with its payload.
        let plain = Self.connection(reportsSites: false, always: true)
        plain.diagnosticSites.install { _ in relayed.withLock { $0 += 1 } }
        try await plain.start()
        _ = try await plain.request(Done())
        var payload: JSONValue?
        for try await envelope in plain.events {
            if case .unknown(let name, let value) = envelope.event, name == DaemonDiagnosticSite.eventName {
                payload = value
                break
            }
        }
        await plain.close()
        #expect(payload?["family"]?.stringValue == "blocking")
        #expect(relayed.withLock { $0 } == 0)
    }
}
