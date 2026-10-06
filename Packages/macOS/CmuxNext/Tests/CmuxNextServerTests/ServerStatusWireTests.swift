@testable import CmuxNextServer
import Foundation
import Testing

struct ServerStatusWireTests {
    private let json = """
    {
      "host_name": "build-01", "platform": "linux", "enabled": true, "mode": "system",
      "roles": {"session": "on", "link": "on", "browser": "unavailable", "postgres": "starting", "future": "on", "apps": "weird"},
      "terminals": 31,
      "app_servers": [
        {"app": "dev.cmux.tasks", "name": "Tasks", "state": "running", "lease_epoch": 7, "holds_lease": true,
         "durability": "zero-loss", "last_restart_ms": 1790900000000},
        {"app": "dev.cmux.ci", "name": "CI", "state": "exploded", "lease_epoch": 2, "holds_lease": false, "durability": "bounded"}
      ],
      "databases": [{"app": "Tasks", "size_bytes": 4096, "quota_bytes": 8192}],
      "browser": {"state": "running", "pages": 2},
      "automations": 3,
      "pairing": {"state": "unpaired", "code": "7kq4-m2xd", "expires_at_ms": 1790976600000,
                  "words": ["copper", "lantern", "meadow", "violet"], "fingerprint": "Q4M2XD7KHJ9P3RTV"},
      "devices": [{"id": "dev_1", "name": "iPhone", "kind": "phone", "last_seen_ms": 1790970000000},
                  {"id": "dev_2", "name": "Fridge", "kind": "toaster"}],
      "checks": ["disk.low", "linger.off", "gpu.thermal"],
      "alerts": [
        {"check": "linger.off", "severity": "critical", "title": "Stops at logout", "body": "b",
         "fix": {"title": "Enable Linger", "needs_admin": true}, "raised_at_ms": 1790975000000},
        {"check": "disk.low", "severity": "warning", "title": "Low", "body": "b",
         "raised_at_ms": 1790970000000, "resolved_at_ms": 1790971000000}
      ],
      "store": {"version": "0.41.7", "channel": "stable", "pinned": true}
    }
    """

    @Test func statusMapsIntoTheSnapshot() throws {
        let snapshot = try ServerStatusWire.decode(Data(json.utf8))
        #expect(snapshot.hostName == "build-01")
        #expect(snapshot.platform == .linux)
        #expect(snapshot.mode == .system)
        #expect(snapshot.roles == [
            ServerRoleStatus(.session, .on), ServerRoleStatus(.link, .on), ServerRoleStatus(.apps, .unavailable),
            ServerRoleStatus(.postgres, .starting), ServerRoleStatus(.browser, .unavailable),
        ], "unknown roles drop, unknown states read as unavailable, order follows ServerRole")
        #expect(snapshot.state(of: .automations) == .off)
        #expect(snapshot.appServers.map(\.state) == [.running, .stopped])
        #expect(snapshot.appServers.first?.durability == .zeroLoss)
        #expect(snapshot.appServers.first?.leaseEpoch == 7)
        #expect(snapshot.appServers.last?.holdsLease == false)
        #expect(snapshot.databases.first?.usage == 0.5)
        #expect(snapshot.browser == .running(pages: 2))
        #expect(snapshot.pairing.offer?.code == "7KQ4M2XD")
        #expect(snapshot.pairing.offer?.qrPayload == "https://cmux.com/pair?c=7KQ4M2XD#fp=Q4M2XD7KHJ9P3RTV")
        #expect(snapshot.devices.map(\.id) == ["dev_1"], "unknown device kinds drop")
        #expect(snapshot.checks.map(\.rawValue) == ["disk.low", "linger.off", "gpu.thermal"])
        #expect(snapshot.alerts.first?.fix == HealthFix(title: "Enable Linger", needsAdmin: true))
        #expect(snapshot.alerts.last?.isOpen == false)
        #expect(snapshot.store == ServerStoreInfo(version: "0.41.7", channel: "stable", pinned: true))
    }

    @Test func pairedAndPairingStatesMap() throws {
        let paired = json.replacingOccurrences(
            of: #""state": "unpaired", "code": "7kq4-m2xd""#,
            with: #""state": "paired", "team": "Manaflow", "owner": "Lawrence", "host": "host_1", "code": "x""#)
        let snapshot = try ServerStatusWire.decode(Data(paired.utf8))
        #expect(snapshot.pairing == .paired(ServerPairing(team: "Manaflow", owner: "Lawrence", hostID: "host_1")))
    }

    @Test @MainActor func everyScenarioIsInternallyConsistent() {
        for scenario in MockServerScenario.allCases {
            let snapshot = scenario.snapshot(now: MockServerScenario.referenceDate)
            for alert in snapshot.alerts {
                #expect(snapshot.checks.contains(alert.check), "\(scenario): \(alert.check) is a check it runs")
            }
            #expect(Set(snapshot.roles.map(\.role)).count == snapshot.roles.count)
        }
    }
}
