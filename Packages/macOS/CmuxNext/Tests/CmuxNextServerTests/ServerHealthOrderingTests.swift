@testable import CmuxNextServer
import Foundation
import Testing

struct ServerHealthOrderingTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func alert(_ check: HealthCheckID, _ severity: HealthSeverity, at offset: TimeInterval, resolvedAt: TimeInterval? = nil) -> HealthAlert {
        HealthAlert(check: check, severity: severity, title: check.rawValue, body: "",
                    raisedAt: t0.addingTimeInterval(offset), resolvedAt: resolvedAt.map { t0.addingTimeInterval($0) })
    }

    @Test func openAlertsAreCriticalThenWarningThenInfoNewestFirst() {
        let alerts = [
            alert(.sleepEnabled, .info, at: 50),
            alert(.diskLow, .warning, at: 10),
            alert(.onBattery, .critical, at: 5),
            alert(.lockPending, .warning, at: 40),
            alert(.offline, .critical, at: 1, resolvedAt: 30),
        ]
        #expect(HealthOrdering.open(alerts).map(\.check) == [.onBattery, .lockPending, .diskLow, .sleepEnabled])
        #expect(HealthOrdering.worst(alerts) == .critical)
    }

    @Test func checklistHidesResolvedAndListsPassingChecksAfterIssues() {
        let checks: [HealthCheckID] = [.onBattery, .offline, .diskLow, .sleepEnabled]
        let alerts = [
            alert(.sleepEnabled, .info, at: 5),
            alert(.diskLow, .critical, at: 1),
            alert(.offline, .critical, at: 2, resolvedAt: 3),
        ]
        let rows = HealthOrdering.checklist(checks: checks, alerts: alerts)
        #expect(rows.map(\.check) == [.diskLow, .sleepEnabled, .onBattery, .offline])
        #expect(rows.map { $0.alert?.severity } == [.critical, .info, nil, nil])
    }

    @Test func checklistKeepsAnAlertForACheckTheListDoesNotName() {
        let future = HealthCheckID("gpu.thermal")
        let rows = HealthOrdering.checklist(checks: [.diskLow], alerts: [alert(future, .warning, at: 1)])
        #expect(rows.map(\.check) == [future, .diskLow])
    }

    @Test func timelineOrdersByLatestEventIncludingResolves() {
        let alerts = [
            alert(.onBattery, .warning, at: 10, resolvedAt: 100),
            alert(.diskLow, .warning, at: 50),
            alert(.offline, .critical, at: 1, resolvedAt: 20),
        ]
        #expect(HealthOrdering.timeline(alerts).map(\.check) == [.onBattery, .diskLow, .offline])
    }

    @Test func noOpenAlertsMeansNoWorstSeverity() {
        #expect(HealthOrdering.worst([alert(.diskLow, .critical, at: 1, resolvedAt: 2)]) == nil)
    }

    @Test func knownChecksAreTheSpecIDs() {
        #expect(HealthCheckID.known.map(\.rawValue) == [
            "power.onBattery", "network.offline", "disk.low", "lock.pending", "sleep.enabled", "restart.noAutoRestart",
            "restart.fileVaultWait", "restart.notLoggedIn", "linger.off", "encryption.off", "postgres.quota", "backup.stale",
        ])
    }
}
