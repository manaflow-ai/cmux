#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
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
    case pairingSetup([MobileWhatsNewFeature])
    case web(URL)
}

struct MobileWhatsNewMacCompatibility: Equatable {
    let stableVersion: String?
    let nightlyVersion: String?
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
    /// Build channels this catalog entry may render on
    /// (``MobileBuildType/token`` values). `nil` (the norm) means the
    /// ``MobileWhatsNewChannelPolicy`` default: team lanes only, never the
    /// official App Store app. The remote list can override per entry
    /// (`entryChannels`), so an entry can be opted into official without a
    /// binary change. Only meaningful for binary catalog entries; resolved
    /// announcements are channel-filtered before page construction.
    var channels: [String]? = nil
    /// One quiet line under the feature rows (compatibility notes and other
    /// fine print that must not compete with the features). `nil` hides it.
    var footnote: String? = nil

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
struct MobileWhatsNewCatalog: Sendable {
    init() {}

    /// Newest first. The one-time sheet shows every visible entry newer than
    /// the acknowledgement marker.
    var entries: [MobileWhatsNewPage] {
        [pairingOptInUpdate, connectionsUpdate]
    }

    func entry(withID id: String) -> MobileWhatsNewPage? {
        entries.first { $0.id == id }
    }

    /// The catalog restricted to entries this build's channel may show, per
    /// their compiled-in channel declarations. This is the no-remote-list
    /// baseline: never-fetched devices and centerless fallbacks (previews)
    /// use it, so an official App Store build renders NO What's New surface
    /// before its first fetch, while team builds keep the full catalog.
    func channelVisibleEntries(
        buildType: MobileBuildType = .current()
    ) -> [MobileWhatsNewPage] {
        entries.filter { page in
            MobileWhatsNewChannelPolicy().isVisible(
                channelTokens: page.channels,
                buildType: buildType
            )
        }
    }

    /// Catalog position (0 = newest). The unseen computation compares
    /// positions in the FULL catalog so remotely hiding one entry cannot
    /// shift how other entries compare against the marker.
    func index(ofID id: String) -> Int? {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            return index
        }
        // The first pairing announcement preceded connections.v2. Its marker
        // sits between the current pairing page and the older connection page.
        switch id {
        case "pairing-opt-in.v1":
            return 1
        default:
            return nil
        }
    }

    var pairingOptInUpdate: MobileWhatsNewPage {
        MobileWhatsNewPage(
            id: "connections.v2",
            releaseLabel: L10n.string(
                "mobile.pairingOptInUpdate.releaseLabel",
                defaultValue: "1.0.4 · September 2026"
            ),
            title: L10n.string(
                "mobile.whatsNew.pairing.pageTitle",
                defaultValue: "Action Required: Enable iOS pairing on your Mac"
            ),
            body: .pairingSetup([]),
            isAnnouncement: false
        )
    }

    var connectionsUpdate: MobileWhatsNewPage {
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
            isAnnouncement: false,
            // The compat requirement is one compact notice under the feature
            // rows (owner feedback: the old full-width warning row read as
            // clutter, and BETA users need the revert path).
            footnote: macUpdateDetail(
                buildType: .current(),
                requiredVersion: macCompatibility(
                    policy: .baked,
                    iosVersion: AppVersionInfo.current().marketingVersion,
                    buildType: .current()
                ).stableVersion
            )
        )
    }

    func macCompatibility(
        policy: MobileMacCompatPolicy,
        iosVersion: String,
        buildType: MobileBuildType
    ) -> MobileWhatsNewMacCompatibility {
        guard let tier = policy.tier(forIOSVersion: iosVersion) else {
            return .init(stableVersion: nil, nightlyVersion: nil)
        }
        let requirement = tier.buildKinds[buildType.token]
            ?? .init(stableMinVersion: tier.stableMinVersion, nightly: tier.nightly)
        let nightlyVersion = requirement.nightly.map {
            "\($0.minBaseVersion.description)-nightly.\($0.minBuild)"
        }
        return .init(
            stableVersion: requirement.stableMinVersion.description,
            nightlyVersion: nightlyVersion
        )
    }

    func macUpdateDetail(
        buildType: MobileBuildType,
        requiredVersion: String?
    ) -> String {
        let version = requiredVersion ?? L10n.string(
            "mobile.connectionsUpdate.macUpdate.requiredVersion",
            defaultValue: "the latest cmux NIGHTLY or cmux RELEASE"
        )
        if buildType.usesInternalBuildVocabulary {
            return String(
                format: L10n.string(
                    "mobile.connectionsUpdate.macUpdate.detail",
                    defaultValue: "Use cmux %@ or later. Older Macs: use BETA 1.0.4 (20260817224846)."
                ),
                version
            )
        }
        return String(
            format: L10n.string(
                "mobile.connectionsUpdate.macUpdate.detail.official",
                defaultValue: "Use cmux %@ or later on your Mac before connecting."
            ),
            version
        )
    }
}
#endif
