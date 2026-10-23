public import Foundation

/// One Dev build in `dev-builds.json` (schema `cmux-dev-builds-v1`), the list CI writes beside the
/// appcast: every Dev build cut from a feat-cmux-next head, newest first, at most 20.
nonisolated public struct DevBuild: Equatable, Sendable {
    /// `CFBundleVersion`.
    public var build: String
    /// `CFBundleShortVersionString`.
    public var version: String
    /// The feat-cmux-next commit it was built from (40 hex).
    public var sha: String
    public var builtAt: Date?
    /// The PR title, else the commit subject.
    public var title: String?
    public var pr: Int?
    /// The signed DMG; it stays downloadable while the build is listed.
    public var url: URL
    public var length: Int?
    /// The archive's EdDSA signature (base64), checked against `SUPublicEDKey` before it installs.
    public var edSignature: String
    public var minimumSystemVersion: SystemVersion?
}

/// `dev-builds.json`: the recent Dev builds, newest first.
nonisolated public struct DevBuildsFeed: Equatable, Sendable {
    public static let schema = "cmux-dev-builds-v1"
    public static let fileName = "dev-builds.json"

    public var builds: [DevBuild]

    /// The sidecar beside `feedURL` (the appcast this Mac reads, or its test feed).
    public static func url(besideFeed feedURL: String) -> URL? {
        URL(string: feedURL)?.deletingLastPathComponent().appending(path: fileName)
    }

    /// Reads the sidecar; a build with a missing or malformed field is left out, not the whole list.
    public static func decode(_ data: Data) throws -> DevBuildsFeed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schema"] as? String == schema, let rows = root["builds"] as? [[String: Any]] else {
            throw AppcastParseError(message: "\(fileName) is not \(schema)")
        }
        let dates = ISO8601DateFormatter()
        let builds = rows.compactMap { row -> DevBuild? in
            guard let build = row["build"] as? String, !build.isEmpty, build.allSatisfy(\.isNumber),
                  let sha = row["sha"] as? String, sha.count == 40, sha.allSatisfy(\.isHexDigit),
                  let link = row["url"] as? String, let url = URL(string: link), url.scheme == "https",
                  let signature = row["ed_signature"] as? String, !signature.isEmpty else { return nil }
            return DevBuild(build: build, version: row["version"] as? String ?? build, sha: sha.lowercased(),
                            builtAt: (row["built_at"] as? String).flatMap(dates.date(from:)), title: row["title"] as? String,
                            pr: row["pr"] as? Int, url: url, length: row["length"] as? Int, edSignature: signature,
                            minimumSystemVersion: (row["minimum_system_version"] as? String).flatMap { SystemVersion($0) })
        }
        return DevBuildsFeed(builds: builds)
    }

    /// The newest listed build, by build number.
    public var newest: DevBuild? {
        builds.max { AppcastSelector.isOlder($0.build, than: $1.build) }
    }
}
