#if os(iOS)
import CmuxMobileSupport

/// Localized display labels for the Mac-chosen mobile transport mode
/// (`cmuxRelay`/`ownRelay`/`tailscale`), shared by the Computers row badge and
/// the computer detail sheet so both surfaces render the same wording. Unknown
/// future modes fall through to their raw value so a new mode is visible before
/// this app learns its display name.
enum MobileTransportModeLabel {
    static func label(for rawMode: String?) -> String? {
        switch rawMode {
        case nil: return nil
        case "cmuxRelay":
            return L10n.string("mobile.computers.transport.cmuxRelay", defaultValue: "cmux relay")
        case "ownRelay":
            return L10n.string("mobile.computers.transport.ownRelay", defaultValue: "own relay")
        case "tailscale":
            return L10n.string("mobile.computers.transport.tailscale", defaultValue: "Tailscale")
        case .some(let raw): return raw
        }
    }
}
#endif
