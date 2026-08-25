#if os(iOS)
import Foundation

/// The remote What's New list served by `/api/whats-new`.
///
/// `visibleEntryIds` is the authoritative set of binary catalog ids the app
/// may show, so a bad or mistimed page can be hidden remotely after release.
/// `announcements` are remote-only entries (service announcements, backend
/// news) targeted at a version range.
struct MobileWhatsNewRemoteList: Codable {
    var visibleEntryIds: [String]
    var announcements: [MobileWhatsNewRemoteAnnouncement]

    init(
        visibleEntryIds: [String],
        announcements: [MobileWhatsNewRemoteAnnouncement]
    ) {
        self.visibleEntryIds = visibleEntryIds
        self.announcements = announcements
    }

    /// Announcements decode lossily: one malformed entry (missing required
    /// version bounds, wrong types) drops that entry, not the whole list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibleEntryIds = try container.decode([String].self, forKey: .visibleEntryIds)
        var decoded: [MobileWhatsNewRemoteAnnouncement] = []
        if var elements = try? container.nestedUnkeyedContainer(forKey: .announcements) {
            while !elements.isAtEnd {
                if let announcement = try? elements.decode(MobileWhatsNewRemoteAnnouncement.self) {
                    decoded.append(announcement)
                } else {
                    // Consume the malformed element so decoding advances.
                    _ = try? elements.decode(DiscardedElement.self)
                }
            }
        }
        announcements = decoded
    }

    private struct DiscardedElement: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// A remote-only What's New entry. Version targeting is REQUIRED: the entry
/// renders only when the app's short version string is inside
/// `minVersion...maxVersion` (inclusive, dotted-numeric compare).
///
/// Content resolution order:
/// 1. `nativeEntryId` present in this binary's catalog: render that native
///    page (newer binaries show native content).
/// 2. `webUrl` on a cmux-owned host: render the webpage in-app (older
///    binaries without the native id get the web fallback).
/// 3. Inline `features` rows.
/// An announcement resolving to none of these is skipped.
struct MobileWhatsNewRemoteAnnouncement: Codable, Identifiable {
    struct Feature: Codable {
        var symbol: String?
        var title: String
        var detail: String
    }

    var id: String
    var minVersion: String
    var maxVersion: String
    var title: String?
    var releaseLabel: String?
    var features: [Feature]?
    var nativeEntryId: String?
    var webUrl: String?
}

/// Dotted-numeric ("1.0.4"-style) version comparison; missing components are
/// zero and non-numeric components compare as zero.
enum MobileAppVersionCompare {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = components(of: lhs)
        let rhsParts = components(of: rhs)
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let l = index < lhsParts.count ? lhsParts[index] : 0
            let r = index < rhsParts.count ? rhsParts[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    static func version(
        _ version: String,
        isWithinMin minVersion: String,
        max maxVersion: String
    ) -> Bool {
        compare(version, minVersion) != .orderedAscending
            && compare(version, maxVersion) != .orderedDescending
    }

    private static func components(of version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
    }
}
#endif
