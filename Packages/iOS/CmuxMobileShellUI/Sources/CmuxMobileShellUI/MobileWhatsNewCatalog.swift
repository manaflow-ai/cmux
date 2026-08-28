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
    /// Filled in precisely at the accompanying Mac release cut; the What's
    /// New compat notice interpolates it. ONE value to edit at cut time.
    static let requiredMacVersionLabel = L10n.string(
        "mobile.connectionsUpdate.macUpdate.requiredVersion",
        defaultValue: "the latest cmux NIGHTLY or cmux RELEASE"
    )

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
                        defaultValue: "Each computer now picks how this iPhone reaches it: Relay or Tailscale Only. Set it in Computers → your computer → Connection Method."
                    )
                ),
                .init(
                    symbol: "bolt.horizontal",
                    title: L10n.string(
                        "mobile.connectionsUpdate.relay.title",
                        defaultValue: "New: Relay connections"
                    ),
                    detail: L10n.string(
                        "mobile.connectionsUpdate.relay.detail",
                        defaultValue: "Your phone now reaches your Mac through the cmux relay from any network. No VPN and no setup; both devices verify your account, and the relay cannot read your terminals."
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
                // Owner directive: this compat notice stays the LAST row so it
                // reads as the prominent bottom section of the page.
                .init(
                    symbol: "exclamationmark.triangle.fill",
                    title: L10n.string(
                        "mobile.connectionsUpdate.macUpdate.title",
                        defaultValue: "Action required: update your Mac"
                    ),
                    detail: String(
                        format: L10n.string(
                            "mobile.connectionsUpdate.macUpdate.detail",
                            defaultValue: "This iPhone update speaks a new connection protocol and only pairs with an updated Mac. Update cmux on your Mac to %@ before connecting. Not ready to update your Mac? Stay on (or revert to) cmux BETA TestFlight version 1.0.4 (20260817224846), the last version that works with older Macs."
                        ),
                        requiredMacVersionLabel
                    )
                ),
            ]),
            isAnnouncement: false
        )
    }
}
#endif
