public import Foundation

/// One alert from the health reducer. The server writes title and body
/// (they carry live numbers); the app names the check itself.
public nonisolated struct HealthAlert: Sendable, Equatable, Identifiable {
    public var check: HealthCheckID
    public var severity: HealthSeverity
    public var title: String
    public var body: String
    public var fix: HealthFix?
    public var raisedAt: Date
    public var resolvedAt: Date?

    /// One alert per check and raise time (the dedupe key plus history).
    public var id: String { "\(check.rawValue)@\(raisedAt.timeIntervalSince1970)" }
    public var isOpen: Bool { resolvedAt == nil }

    public init(check: HealthCheckID, severity: HealthSeverity, title: String, body: String,
                fix: HealthFix? = nil, raisedAt: Date, resolvedAt: Date? = nil) {
        self.check = check
        self.severity = severity
        self.title = title
        self.body = body
        self.fix = fix
        self.raisedAt = raisedAt
        self.resolvedAt = resolvedAt
    }
}

/// Health as the three prototype views read it. Pure, so tests pin the order.
public nonisolated enum HealthOrdering {
    /// Open alerts only: critical, then warning, then info; newest first
    /// within a severity; check id breaks ties.
    public static func open(_ alerts: [HealthAlert]) -> [HealthAlert] {
        alerts.filter(\.isOpen).sorted(by: urgencyOrder)
    }

    /// One row per check the server runs: checks with an open alert first
    /// (urgency order), then the passing checks in their reported order.
    /// Resolved alerts never show here.
    public static func checklist(checks: [HealthCheckID], alerts: [HealthAlert]) -> [HealthChecklistRow] {
        let openAlerts = open(alerts)
        var seen = Set<HealthCheckID>()
        var rows: [HealthChecklistRow] = []
        for alert in openAlerts where seen.insert(alert.check).inserted {
            rows.append(HealthChecklistRow(check: alert.check, alert: alert))
        }
        for check in checks where seen.insert(check).inserted {
            rows.append(HealthChecklistRow(check: check, alert: nil))
        }
        return rows
    }

    /// Every alert, open and resolved, newest event first (a resolve counts
    /// as an event at its resolve time).
    public static func timeline(_ alerts: [HealthAlert]) -> [HealthAlert] {
        alerts.sorted { a, b in
            let ta = a.resolvedAt ?? a.raisedAt
            let tb = b.resolvedAt ?? b.raisedAt
            return ta != tb ? ta > tb : a.check.rawValue < b.check.rawValue
        }
    }

    /// The most urgent open severity, nil when every check passes.
    public static func worst(_ alerts: [HealthAlert]) -> HealthSeverity? {
        alerts.filter(\.isOpen).map(\.severity).max()
    }

    private static func urgencyOrder(_ a: HealthAlert, _ b: HealthAlert) -> Bool {
        if a.severity != b.severity { return a.severity > b.severity }
        if a.raisedAt != b.raisedAt { return a.raisedAt > b.raisedAt }
        return a.check.rawValue < b.check.rawValue
    }
}

public nonisolated struct HealthChecklistRow: Sendable, Equatable, Identifiable {
    public var check: HealthCheckID
    /// The open alert, nil when the check passes.
    public var alert: HealthAlert?
    public var id: String { check.rawValue }
}
