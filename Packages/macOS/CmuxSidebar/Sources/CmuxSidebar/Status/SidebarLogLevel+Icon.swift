/// SF Symbol icon names for sidebar log severities.
///
/// Lifted byte-identically from the app target's sidebar tab-row renderer
/// (`TabItemView.logLevelIcon`). Each case maps to the SF Symbol the sidebar
/// draws next to the latest log line. These names are presentation constants,
/// not a wire format, and carry no localization, so they live on the owning
/// type rather than in the app target.
extension SidebarLogLevel {
    /// The SF Symbol system name the sidebar draws for this log severity.
    public var iconSystemName: String {
        switch self {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}
