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
