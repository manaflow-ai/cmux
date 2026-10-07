public import Foundation

/// Reads the items of a Sparkle appcast (RSS 2.0 with the `sparkle:`
/// namespace). Only the fields ``AppcastItem`` needs; deltas are skipped.
nonisolated public enum AppcastParser {
    public static func parse(_ data: Data) throws -> [AppcastItem] {
        let delegate = AppcastParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw AppcastParseError(message: parser.parserError.map(String.init(describing:)) ?? "invalid appcast XML")
        }
        guard delegate.sawChannel else { throw AppcastParseError(message: "appcast has no <channel>") }
        return delegate.items
    }
}

/// XMLParser callbacks. Collects `<item>` children, ignoring the
/// enclosures inside `<sparkle:deltas>`.
nonisolated private final class AppcastParserDelegate: NSObject, XMLParserDelegate {
    private(set) var items: [AppcastItem] = []
    private(set) var sawChannel = false
    private var fields: [String: String]?
    private var enclosure: [String: String]?
    private var deltaDepth = 0
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "channel": sawChannel = true
        case "item": fields = [:]; enclosure = nil
        case "sparkle:deltas": deltaDepth += 1
        case "enclosure" where fields != nil && deltaDepth == 0: enclosure = attributes
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        switch name {
        case "sparkle:deltas": deltaDepth -= 1
        case "item": finishItem()
        default:
            guard fields != nil, deltaDepth == 0, !value.isEmpty else { return }
            fields?[name] = value
        }
    }

    private func finishItem() {
        guard let fields else { return }
        self.fields = nil
        let enclosure = enclosure ?? [:]
        guard let version = fields["sparkle:version"] ?? enclosure["sparkle:version"] else { return }
        items.append(AppcastItem(
            version: version,
            displayVersion: fields["sparkle:shortVersionString"] ?? enclosure["sparkle:shortVersionString"],
            title: fields["title"],
            minimumSystemVersion: fields["sparkle:minimumSystemVersion"].flatMap(SystemVersion.init),
            maximumSystemVersion: fields["sparkle:maximumSystemVersion"].flatMap(SystemVersion.init),
            releaseNotesURL: (fields["sparkle:fullReleaseNotesLink"] ?? fields["sparkle:releaseNotesLink"]).flatMap(URL.init(string:)),
            downloadURL: enclosure["url"].flatMap(URL.init(string:))
        ))
    }
}
