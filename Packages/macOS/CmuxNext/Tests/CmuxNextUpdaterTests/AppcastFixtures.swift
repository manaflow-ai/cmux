import Foundation
@testable import CmuxNextUpdater

/// Appcast XML shaped like the published feeds (generate_appcast output).
enum AppcastFixtures {
    static func item(_ version: String, short: String? = nil, minimum: String? = "26.0", maximum: String? = nil, deltas: Bool = false) -> String {
        """
        <item>
            <title>\(short ?? version)</title>
            <sparkle:fullReleaseNotesLink>https://github.com/manaflow-ai/cmux/releases/tag/v\(short ?? version)</sparkle:fullReleaseNotesLink>
            <sparkle:version>\(version)</sparkle:version>
            <sparkle:shortVersionString>\(short ?? version)</sparkle:shortVersionString>
            \(minimum.map { "<sparkle:minimumSystemVersion>\($0)</sparkle:minimumSystemVersion>" } ?? "")
            \(maximum.map { "<sparkle:maximumSystemVersion>\($0)</sparkle:maximumSystemVersion>" } ?? "")
            <enclosure url="https://github.com/manaflow-ai/cmux/releases/download/v\(version)/cmux-macos.dmg" length="3" type="application/octet-stream" sparkle:edSignature="sig"/>
            \(deltas ? "<sparkle:deltas><enclosure url=\"https://example.invalid/old.delta\" sparkle:version=\"999999999999999\" sparkle:deltaFrom=\"1\" length=\"1\" type=\"application/octet-stream\"/></sparkle:deltas>" : "")
        </item>
        """
    }

    static func feed(_ items: String...) -> Data {
        Data("""
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <title>cmux</title>
                \(items.joined(separator: "\n"))
            </channel>
        </rss>
        """.utf8)
    }

    static func identity(bundle: String = "com.cmuxterm.app", build: String = "106", short: String = "0.64.25",
                         feed: String? = "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml",
                         key: Bool = true) -> UpdateBuildIdentity {
        UpdateBuildIdentity(bundleIdentifier: bundle, shortVersion: short, build: build,
                            minimumSystemVersion: SystemVersion("26.0"), infoFeedURL: feed, hasPublicKey: key)
    }
}

/// Serves one fixed response and records the URLs asked for.
final class FixtureFetcher: AppcastFetching, @unchecked Sendable {
    let data: Data?
    private(set) var requested: [URL] = []

    init(_ data: Data?) {
        self.data = data
    }

    func fetch(_ url: URL) async throws -> Data {
        requested.append(url)
        guard let data else { throw AppcastParseError(message: "offline") }
        return data
    }
}
