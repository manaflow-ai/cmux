public import Foundation

/// Turns design mode's page messages into composer cards for one tab, remembering which
/// highlights it already sent so a snapshot that only scrolled sends nothing.
///
/// The messages are the ones classic's `BrowserDesignModeRuntime.js` posts to
/// `cmuxDesignMode`: `{type: "snapshot", snapshot: {selections: [...]}}` after every change.
/// A highlight is keyed by its first selector (a drawn region by `@annotation(<id>)`); one that
/// leaves the snapshot is forgotten, so highlighting it again sends it again under the same id.
///
/// ```swift
/// var cards = BrowserDesignModeCards()
/// for card in cards.receive(message, pageURL: tab.state.url) { send(card) }
/// ```
public nonisolated struct BrowserDesignModeCards: Sendable {
    /// The keys of the highlights the latest snapshot holds that were already sent.
    private var sent: Set<String> = []

    public init() {}

    /// The cards for highlights in `message` (`{type: "snapshot", snapshot}`) not sent before.
    /// - Parameters:
    ///   - message: One page message as JSON.
    ///   - pageURL: The tab's page, named on each card.
    /// - Returns: New cards in highlight order; none for any other message.
    public mutating func receive(_ message: Data, pageURL: URL?) -> [BrowserDesignModeCard] {
        guard let body = Self.object(message), body["type"] as? String == "snapshot",
              let snapshot = body["snapshot"] as? [String: Any] else { return [] }
        let selections = (snapshot["selections"] as? [[String: Any]]) ?? []
        var present: Set<String> = []
        var cards: [BrowserDesignModeCard] = []
        for selection in selections {
            guard let key = selection["selector"] as? String, !key.isEmpty else { continue }
            present.insert(key)
            guard !sent.contains(key) else { continue }
            cards.append(Self.card(selection, key: key, pageURL: pageURL))
        }
        sent = present
        return cards
    }

    /// Forgets what was sent (design mode turned off, or a new document).
    public mutating func reset() { sent = [] }

    /// True for the page's `exit_requested` (Escape with nothing highlighted).
    public static func isExitRequest(_ message: Data) -> Bool {
        object(message)?["type"] as? String == "exit_requested"
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func card(_ selection: [String: Any], key: String, pageURL: URL?) -> BrowserDesignModeCard {
        let tag = (selection["tag_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "element"
        let host = pageURL.map { $0.isFileURL ? $0.lastPathComponent : ($0.host() ?? $0.absoluteString) } ?? ""
        let bounds = selection["bounds"] as? [String: Any]
        let viewport = selection["viewport"] as? [String: Any]
        let picked = pickedVariation(selection, key: key)
        var text = agentText(selection, key: key, tag: tag, pageURL: pageURL)
        if let picked {
            let title = ((selection["text_content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = title.replacingOccurrences(of: "^\\d+\\.\\s*", with: "", options: .regularExpression)
            text = "Picked design variation \(picked)" + (stripped.isEmpty ? "" : ": \(stripped)") + "\n\n" + text
        }
        return BrowserDesignModeCard(
            id: "design-" + stableHash(key + "|" + (pageURL?.absoluteString ?? "")),
            name: Strings.designModeCardName(tag: tag, host: host),
            text: text,
            bounds: CGRect(x: number(bounds?["x"]), y: number(bounds?["y"]),
                           width: number(bounds?["width"]), height: number(bounds?["height"])),
            viewportWidth: number(viewport?["width"]),
            pickedVariation: picked
        )
    }

    /// The variation a gallery tile names (`data-testid="cmux-variation-<n>"`, or its caption's
    /// `cmux-variation-<n>-title`, scripts/cmux-next/design-variations.py); nil for other elements.
    private static func pickedVariation(_ selection: [String: Any], key: String) -> Int? {
        let selectors = [key] + ((selection["selectors"] as? [String]) ?? [])
        for selector in selectors {
            guard let match = selector.firstMatch(of: /data-testid="cmux-variation-(\d+)(-title)?"/) else { continue }
            return Int(match.1)
        }
        return nil
    }

    /// What the agent reads. Plain English on purpose: it is prompt text for the agent, not UI.
    private static func agentText(_ selection: [String: Any], key: String, tag: String, pageURL: URL?) -> String {
        var lines = ["Design mode highlight from the cmux browser."]
        if let pageURL { lines.append("Page: \(pageURL.absoluteString)") }
        lines.append("Element: <\(tag)>")
        lines.append("Selector: \(key)")
        let selectors = (selection["selectors"] as? [String]) ?? []
        if selectors.count > 1 { lines.append("Other selectors: " + selectors.dropFirst().joined(separator: " | ")) }
        if let xpath = selection["xpath"] as? String, !xpath.isEmpty { lines.append("XPath: \(xpath)") }
        if let components = selection["react_components"] as? [String], !components.isEmpty {
            lines.append("React components: " + components.joined(separator: " > "))
        }
        if let text = selection["text_content"] as? String, !text.isEmpty { lines.append("Text: \(text)") }
        if let styles = selection["computed_styles"] as? [String: Any], !styles.isEmpty {
            lines.append("Computed styles:")
            for name in styles.keys.sorted() { lines.append("  \(name): \(styles[name].map { "\($0)" } ?? "")") }
        }
        if let snippet = selection["dom_snippet"] as? String, !snippet.isEmpty {
            lines.append("HTML:")
            lines.append(snippet)
        }
        return lines.joined(separator: "\n")
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    /// FNV-1a, stable across launches (Swift's `hashValue` is seeded per process).
    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
