#if os(iOS)
import CmuxMobileSupport
import Foundation

/// One What's New feature row (accent symbol + title + detail), the unit of
/// the HIG What's New template layout shared by binary pages and remote
/// announcements.
struct MobileWhatsNewFeature {
    let symbol: String
    let title: String
    let detail: String
}

/// What a What's New page renders: native feature rows compiled into this
/// binary, or a cmux-owned webpage for content pushed after release.
enum MobileWhatsNewPageBody {
    case features([MobileWhatsNewFeature])
    case web(URL)
}

/// One What's New page: a binary catalog entry or a resolved remote
/// announcement. `id` is the acknowledgement unit; for announcements it is
/// the announcement id even when the body is borrowed from a referenced
/// native catalog entry.
struct MobileWhatsNewPage: Identifiable {
    let id: String
    /// Human-readable release label shown in the archive list
    /// ("1.0.5 · August 2026"). `nil` hides the subtitle row.
    let releaseLabel: String?
    let title: String
    let body: MobileWhatsNewPageBody
    /// Remote announcements are visually marked to distinguish service news
    /// from binary release notes.
    let isAnnouncement: Bool

    /// SwiftUI list identity, namespaced by kind so an announcement id can
    /// never collide with a binary entry id in a mixed list (the server
    /// cannot validate against catalog entries it does not know about, such
    /// as remotely hidden ones that are later re-enabled).
    var listID: String {
        (isAnnouncement ? "announcement:" : "entry:") + id
    }
}

/// Version-keyed release notes compiled into this binary, newest first.
///
/// New releases PREPEND entries. An id is permanent once shipped: the
/// device's acknowledgement marker and the remote visibility list
/// (`/api/whats-new` `visibleEntryIds`) both reference it, and the
/// unseen computation orders pages by catalog index.
enum MobileWhatsNewCatalog {
    /// Newest first. The one-time sheet shows every visible entry newer than
    /// the acknowledgement marker.
    static var entries: [MobileWhatsNewPage] {
        [connectionsUpdate]
    }

    static func entry(withID id: String) -> MobileWhatsNewPage? {
        entries.first { $0.id == id }
    }

    /// Catalog position (0 = newest). The unseen computation compares
    /// positions in the FULL catalog so remotely hiding one entry cannot
    /// shift how other entries compare against the marker.
    static func index(ofID id: String) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    static var connectionsUpdate: MobileWhatsNewPage {
        MobileWhatsNewPage(
            id: "connections.v1",
            releaseLabel: L10n.string(
                "mobile.connectionsUpdate.releaseLabel",
                defaultValue: "1.0.5 · August 2026"
            ),
            title: L10n.string(
                "mobile.connectionsUpdate.title",
                defaultValue: "What's New in cmux"
            ),
            body: .features([
                .init(
                    symbol: "desktopcomputer.and.macbook",
                    title: L10n.string(
                        "mobile.connectionsUpdate.perComputer.title",
                        defaultValue: "Per-computer methods"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.perComputer.detail",
                        defaultValue: "Each computer now picks how this iPhone reaches it: Iroh, Tailscale Only, or Direct. Set it in Computers → your computer → Connection Method."
                    )
                ),
                .init(
                    symbol: "bolt.horizontal",
                    title: L10n.string(
                        "mobile.connectionsUpdate.iroh.title",
                        defaultValue: "Auto-Connect is now Iroh"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.iroh.detail",
                        defaultValue: "Same authenticated, end-to-end encrypted connection, now with a clearer name. The app-wide setting moved out of Settings."
                    )
                ),
                .init(
                    symbol: "network",
                    title: L10n.string(
                        "mobile.connectionsUpdate.direct.title",
                        defaultValue: "New: Direct addresses"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.direct.detail",
                        defaultValue: "On your LAN, WireGuard, or any other network: add the addresses where a computer is reachable and dial exactly those, with no fallback."
                    )
                ),
                .init(
                    symbol: "qrcode.viewfinder",
                    title: L10n.string(
                        "mobile.connectionsUpdate.tailscale.title",
                        defaultValue: "Tailscale, on your terms"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.tailscale.detail",
                        defaultValue: "Choosing Tailscale Only shows exactly what's missing and offers the pairing-code scan right there. Nothing opens on its own."
                    )
                ),
            ]),
            isAnnouncement: false
        )
    }
}
#endif
