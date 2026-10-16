import Foundation

extension CloudTunnelBanner {
    /// A stable state-and-copy identity for dismissing the Machines banner.
    public var dismissalSignature: String {
        String(describing: kind) + "|" + text + "|" + String(opensSystemSettings)
    }
}

extension MachinePlanSnapshot.FreeAccessBanner {
    /// Keeps dismissal across countdown ticks; a new warning stage resurfaces the banner.
    public var dismissalSignature: String {
        switch self {
        case .none: return "none"
        case .expiresIn: return "expires-in"
        case .expiresToday: return "expires-today"
        case .expired: return "expired"
        }
    }
}
