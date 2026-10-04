@testable import CmuxNextServer
import Foundation
import Testing

/// `cmux server status --json` and `cmux host roles --json` map into a
/// snapshot, tolerant of fields a newer server adds or an older one lacks.
struct LocalServerStatusTests {
    /// The shape `cmux server status --json` prints today (cmux-server cli/lifecycle.rs).
    static let status = Data("""
    {"enabled": true, "mode": "user",
     "store": {"generation": 3, "version": "0.9.1", "channel": "stable", "pinned": "0.9.1",
               "generations": [2, 3], "last_applied_sequence": 7, "packages": [{"name": "cmux", "version": "0.9.1"}]},
     "service": {"installed": true, "active": true, "enabled": true},
     "postgres": {"port": 55432, "state": "running"},
     "roles": [], "apps": [], "alerts": [], "future_field": {"nested": [1, 2]}}
    """.utf8)

    /// `<state>/roles/status.json` (cmux-host proc_roles, `RoleHealth`).
    static let roles = Data("""
    {"roles": [
      {"name": "session", "state": "ready", "pid": 41, "restarts": 0, "last_exit": null, "last_error": null, "status_text": "ok"},
      {"name": "apps", "state": "crash-loop", "pid": null, "restarts": 5, "last_exit": "code 1", "last_error": "boom", "status_text": null},
      {"name": "updater", "state": "backoff", "pid": null, "restarts": 1, "last_exit": "signal", "last_error": null, "status_text": null},
      {"name": "my-sidecar", "state": "ready", "pid": 99, "restarts": 0},
      {"name": "health", "state": "something-new"},
      {"state": "ready"}
    ]}
    """.utf8)

    @Test func todaysStatusAndRolesMapIntoASnapshot() throws {
        let snapshot = try LocalServerStatus.snapshot(status: Self.status, roles: Self.roles, hostName: "Mac mini")
        #expect(snapshot.hostName == "Mac mini")
        #expect(snapshot.platform == .macOS)
        #expect(snapshot.enabled)
        #expect(snapshot.mode == .user)
        #expect(snapshot.store == ServerStoreInfo(version: "0.9.1", channel: "stable", pinned: true))
        // Known roles in ServerRole order; an unknown name and a nameless entry are dropped;
        // an unknown state reads as unavailable; postgres comes from the cluster state.
        #expect(snapshot.roles == [
            ServerRoleStatus(.session, .on), ServerRoleStatus(.apps, .failed), ServerRoleStatus(.postgres, .on),
            ServerRoleStatus(.health, .unavailable), ServerRoleStatus(.updater, .starting),
        ])
        #expect(snapshot.pairing == .unpaired(nil))
        #expect(snapshot.checks.isEmpty && snapshot.alerts.isEmpty && snapshot.devices.isEmpty)
        #expect(snapshot.appServers.isEmpty && snapshot.databases.isEmpty)
        #expect(snapshot.browser == .off)
    }

    @Test func missingRolesAndAbsentServiceReadAsOff() throws {
        let status = Data(#"{"enabled": false, "mode": "user", "store": {"version": null, "channel": "stable", "pinned": null}, "postgres": {"state": "absent"}}"#.utf8)
        let snapshot = try LocalServerStatus.snapshot(status: status, roles: nil, hostName: "h")
        #expect(!snapshot.enabled)
        #expect(snapshot.roles.isEmpty)
        #expect(snapshot.store == ServerStoreInfo(version: "", channel: "stable", pinned: false))
    }

    @Test func alertsChecksAndPairingAreReadWhenTheServerSendsThem() throws {
        let status = Data("""
        {"enabled": true, "mode": "user", "host_name": "studio", "checks": ["sleep.enabled", "disk.low", 7],
         "alerts": [
           {"check": "sleep.enabled", "severity": "info", "title": "Sleep is on", "body": "b",
            "fix": {"title": "Turn off sleep", "needs_admin": true}, "raised_at_ms": 1000},
           {"check": "disk.low", "severity": "bogus", "title": "Disk", "body": "", "raised_at_ms": 2000, "resolved_at_ms": 3000},
           {"title": "no check"}
         ],
         "pairing": {"state": "paired", "team": "t", "owner": "o", "host": "h1"},
         "roles": {"session": "on", "link": "off"}}
        """.utf8)
        let snapshot = try LocalServerStatus.snapshot(status: status, roles: nil, hostName: "ignored")
        #expect(snapshot.hostName == "studio")
        #expect(snapshot.checks == [.sleepEnabled, .diskLow])
        #expect(snapshot.alerts.count == 2)
        #expect(snapshot.alerts[0].fix == HealthFix(title: "Turn off sleep", needsAdmin: true))
        #expect(snapshot.alerts[1].severity == .warning)
        #expect(snapshot.alerts[1].resolvedAt == Date(timeIntervalSince1970: 3))
        #expect(snapshot.pairing == .paired(ServerPairing(team: "t", owner: "o", hostID: "h1")))
        #expect(snapshot.roles == [ServerRoleStatus(.session, .on), ServerRoleStatus(.link, .off)])
    }

    @Test func aTopLevelThatIsNotAnObjectIsMalformed() {
        #expect(throws: LocalServerStatus.Malformed.self) {
            try LocalServerStatus.snapshot(status: Data("[]".utf8), roles: nil, hostName: "h")
        }
        #expect(throws: LocalServerStatus.Malformed.self) {
            try LocalServerStatus.snapshot(status: Data("cmux server: not json".utf8), roles: nil, hostName: "h")
        }
    }

    /// A `cmux` without the server verbs answers `server status` with the
    /// terminal daemon's own status; that is no server's status.
    @Test func theTerminalDaemonsStatusIsNotAServerStatus() {
        let daemon = Data(#"{"status": "running", "session": "cmux-app", "pid": 12}"#.utf8)
        #expect(throws: LocalServerStatus.NotServerStatus.self) {
            try LocalServerStatus.snapshot(status: daemon, roles: nil, hostName: "h")
        }
    }

    @Test func roleStatesFollowTheSupervisorsSpelling() {
        #expect(LocalServerStatus.roleState("ready") == .on)
        #expect(LocalServerStatus.roleState("starting") == .starting)
        #expect(LocalServerStatus.roleState("backoff") == .starting)
        #expect(LocalServerStatus.roleState("stopped") == .off)
        #expect(LocalServerStatus.roleState("exited") == .off)
        #expect(LocalServerStatus.roleState("crash-loop") == .failed)
        #expect(LocalServerStatus.roleState("invalid") == .failed)
        #expect(LocalServerStatus.roleState("new-state") == .unavailable)
    }
}
