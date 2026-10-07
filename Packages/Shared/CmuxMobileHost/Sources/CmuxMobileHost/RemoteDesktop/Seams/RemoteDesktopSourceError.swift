/// Why a desktop could not be described or opened.
public enum RemoteDesktopSourceError: Error, Hashable, Sendable {
    case displayNotFound
    case windowNotFound
    /// A TCC permission is missing (`screen_recording`, `accessibility`).
    case permissionDenied(String)
    /// The VNC server did not answer, or not with RFB.
    case vncUnreachable(String)
    /// The VNC server offered no security type this Mac speaks.
    case vncAuthUnsupported
    case failed(String)

    /// The `channel.refused` / `desktop.ended` code for this error.
    public var code: String {
        switch self {
        case .displayNotFound: "rd.display_not_found"
        case .windowNotFound: "rd.window_not_found"
        case .permissionDenied: "rd.permission_denied"
        case .vncUnreachable: "rd.vnc_unreachable"
        case .vncAuthUnsupported: "rd.vnc_auth_unsupported"
        case .failed: "rd.unavailable"
        }
    }

    /// Worth trying again later (the server or capture may come back).
    public var isRetryable: Bool {
        switch self {
        case .vncUnreachable, .failed: true
        default: false
        }
    }
}
