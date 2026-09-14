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
enum MobileWhatsNewCatalog {
    /// Newest first. The one-time sheet shows every visible entry newer than
    /// the acknowledgement marker.
    static var entries: [MobileWhatsNewPage] {
        [connectionsUpdate]
    }

    static func entry(withID id: String) -> MobileWhatsNewPage? {
        entries.first { $0.id == id }
    }

    /// The catalog restricted to entries this build's channel may show, per
    /// their compiled-in channel declarations. This is the no-remote-list
    /// baseline: never-fetched devices and centerless fallbacks (previews)
    /// use it, so an official App Store build renders NO What's New surface
    /// before its first fetch, while team builds keep the full catalog.
    static func channelVisibleEntries(
        buildType: MobileBuildType = .current()
    ) -> [MobileWhatsNewPage] {
        entries.filter { page in
            MobileWhatsNewChannelPolicy.isVisible(
                channelTokens: page.channels,
                buildType: buildType
            )
        }
    }

    /// Catalog position (0 = newest). The unseen computation compares
    /// positions in the FULL catalog so remotely hiding one entry cannot
    /// shift how other entries compare against the marker.
    static func index(ofID id: String) -> Int? {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            return index
        }
        // These ids were acknowledged by earlier builds. Treat them as an
        // older marker so the consolidated page is shown once, then advance
        // the marker to the current entry id.
        switch id {
        case "pairing-opt-in.v1", "connections.v1":
            return entries.count
        default:
            return nil
        }
    }

    static var connectionsUpdate: MobileWhatsNewPage {
        MobileWhatsNewPage(
            id: "connections.v2",
            releaseLabel: L10n.string(
                "mobile.connectionsUpdate.releaseLabel",
                defaultValue: "1.0.5 · August 2026"
            ),
            title: L10n.string(
                "mobile.whatsNew.pairing.pageTitle",
                defaultValue: "Pairing begins on your Mac"
            ),
            body: .pairingSetup([]),
            isAnnouncement: false
        )
    }

    static func macCompatibility(
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

    static func macUpdateDetail(
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
                    defaultValue: "This iPhone update speaks a new connection protocol and only pairs with an updated Mac. Update cmux on your Mac to %@ before connecting. Not ready to update your Mac? Stay on (or revert to) cmux BETA TestFlight version 1.0.4 (20260817224846), the last version that works with older Macs."
                ),
                version
            )
        }
        return String(
            format: L10n.string(
                "mobile.connectionsUpdate.macUpdate.detail.official",
                defaultValue: "This iPhone update speaks a new connection protocol and only pairs with an updated Mac. Update cmux on your Mac to %@ before connecting."
            ),
            version
        )
    }
}
#endif
