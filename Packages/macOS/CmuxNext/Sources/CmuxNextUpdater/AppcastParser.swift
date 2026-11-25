public import Foundation
import CmuxNextWindowRules

/// Reads the items of a Sparkle appcast (RSS 2.0 with the `sparkle:` namespace): only the fields
/// ``AppcastItem`` needs; deltas are skipped. The reader is cmux-updater-core's (`appcast.rs`),
/// asked over the app FFI (`updater_appcast_parse`), so every platform's updater reads a feed the
/// same way; this maps its answer onto ``AppcastItem``.
nonisolated public enum AppcastParser {
    public static func parse(_ data: Data) throws -> [AppcastItem] {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw AppcastParseError(message: "invalid appcast XML: the feed is not UTF-8")
        }
        guard let reply = WindowRules().call("updater_appcast_parse", ParseRequest(xml: xml), as: ParseReply.self) else {
            throw AppcastParseError(message: "the updater core did not answer")
        }
        if let error = reply.error { throw AppcastParseError(message: error) }
        return (reply.items ?? []).map(\.item)
    }

    private struct ParseRequest: Encodable { var xml: String }
    private struct ParseReply: Decodable { var items: [WireItem]?; var error: String? }

    /// cmux-updater-core's `AppcastItem`.
    private struct WireItem: Decodable {
        var version: String
        var displayVersion: String?
        var title: String?
        var minimumSystemVersion: WireSystemVersion?
        var maximumSystemVersion: WireSystemVersion?
        var releaseNotesUrl: String?
        var downloadUrl: String?
        var itemDescription: String?
        var date: Double?
        var sparkleChannel: String?
        var listsDeltas: Bool?
        var signature: WireSignature?

        var item: AppcastItem {
            AppcastItem(
                version: version, displayVersion: displayVersion, title: title,
                minimumSystemVersion: minimumSystemVersion?.version, maximumSystemVersion: maximumSystemVersion?.version,
                releaseNotesURL: releaseNotesUrl.flatMap(URL.init(string:)), downloadURL: downloadUrl.flatMap(URL.init(string:)),
                itemDescription: itemDescription, date: date.map(Date.init(timeIntervalSince1970:)),
                sparkleChannel: sparkleChannel, listsDeltas: listsDeltas ?? false,
                signature: signature.map { ArchiveSignature(edSignature: $0.edSignature, length: $0.length) })
        }
    }

    private struct WireSignature: Decodable { var edSignature: String; var length: Int? }
}

/// cmux-updater-core's `SystemVersion` on the wire.
nonisolated struct WireSystemVersion: Codable {
    var major: Int
    var minor: Int
    var patch: Int

    init(_ version: SystemVersion) {
        major = version.major
        minor = version.minor
        patch = version.patch
    }

    var version: SystemVersion { SystemVersion(major: major, minor: minor, patch: patch) }
}
