/// Why the Mac ended a desktop session (`desktop.ended`), before `channel.closed`.
public enum DesktopEndReason: String, Hashable, Sendable, CaseIterable {
    case stoppedByHost = "stopped_by_host"
    case consentDenied = "consent_denied"
    case permissionRevoked = "permission_revoked"
    case targetGone = "target_gone"
    case vncClosed = "vnc_closed"
    case vncAuthFailed = "vnc_auth_failed"
    case revoked
}
