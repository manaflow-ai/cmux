/// Severity of a sidebar log entry.
///
/// Raw values are a control-socket wire format; frozen.
public enum SidebarLogLevel: String, Sendable, Equatable {
    case info
    case progress
    case success
    case warning
    case error
}
