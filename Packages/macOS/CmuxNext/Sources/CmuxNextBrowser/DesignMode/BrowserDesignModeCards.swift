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
    /// Per highlight key the latest snapshot holds: its card id and the edits its card carries.
    private var sent: [String: (id: String, edits: String)] = [:]

    public init() {}

    /// The cards for highlights in `message` (`{type: "snapshot", snapshot}`) not sent before, and
    /// for highlights whose edits changed.
    /// - Parameters:
    ///   - message: One page message as JSON.
    ///   - pageURL: The tab's page, named on each card.
    /// - Returns: Cards in highlight order; none for any other message.
    public mutating func receive(_ message: Data, pageURL: URL?) -> [BrowserDesignModeCard] {
        change(message, pageURL: pageURL).cards
    }

    /// What `message` changed: new cards, cards whose edits changed (same id, so the chip is
    /// replaced), and the ids of cards whose highlight left the page. The page's edits (style and
    /// text, `edits` and `css_diff`) belong to its selected element, the last selection.
    public mutating func change(_ message: Data, pageURL: URL?) -> BrowserDesignModeChange {
        guard let body = Self.object(message), body["type"] as? String == "snapshot",
              let snapshot = body["snapshot"] as? [String: Any] else { return BrowserDesignModeChange(cards: [], removed: []) }
        let selections = ((snapshot["selections"] as? [[String: Any]]) ?? []).filter {
            ($0["selector"] as? String).map { !$0.isEmpty } ?? false
        }
        let edits = Self.editsText(snapshot)
        var next: [String: (id: String, edits: String)] = [:]
        var cards: [BrowserDesignModeCard] = []
        for (index, selection) in selections.enumerated() {
            guard let key = selection["selector"] as? String else { continue }
            let selected = index == selections.count - 1
            let mine = selected ? edits : ""
            // An element no longer selected keeps the card (and edits) it was sent with.
            if let old = sent[key], !selected || old.edits == mine {
                next[key] = old
                continue
            }
            let card = Self.card(selection, key: key, pageURL: pageURL, edits: mine)
            next[key] = (card.id, mine)
            cards.append(card)
        }
        let removed = sent.filter { next[$0.key] == nil }.map(\.value.id).sorted()
        sent = next
        return BrowserDesignModeChange(cards: cards, removed: removed)
    }

    /// Forgets what was sent (a new document) without taking cards out.
    public mutating func reset() { sent = [:] }

    /// Forgets every card and returns their ids, to take them out (design mode turned off).
    public mutating func removeAll() -> [String] {
        defer { sent = [:] }
        return sent.values.map(\.id).sorted()
    }

    /// The edits as the agent reads them: the CSS diff, then each text change.
    private static func editsText(_ snapshot: [String: Any]) -> String {
        var lines: [String] = []
        if let css = snapshot["css_diff"] as? String, !css.isEmpty { lines.append(css) }
        for edit in (snapshot["edits"] as? [[String: Any]]) ?? [] where edit["kind"] as? String == "text" {
            let before = (edit["original_value"] as? String) ?? "", after = (edit["value"] as? String) ?? ""
            lines.append("Text changed from \"\(before)\" to \"\(after)\"")
        }
        return lines.joined(separator: "\n")
    }

    /// True for the page's `exit_requested` (Escape with nothing highlighted).
    public static func isExitRequest(_ message: Data) -> Bool {
        object(message)?["type"] as? String == "exit_requested"
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func card(_ selection: [String: Any], key: String, pageURL: URL?, edits: String) -> BrowserDesignModeCard {
        let tag = (selection["tag_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "element"
        let host = pageURL.map { $0.isFileURL ? $0.lastPathComponent : ($0.host() ?? $0.absoluteString) } ?? ""
        let bounds = selection["bounds"] as? [String: Any]
        let viewport = selection["viewport"] as? [String: Any]
        let picked = pickedVariation(selection, key: key)
        var text = agentText(selection, key: key, tag: tag, pageURL: pageURL)
        if !edits.isEmpty { text += "\nEdits made in design mode:\n" + edits }
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
        if let source = selection["source_location"] as? [String: Any],
           let file = source["file"] as? String, let line = source["line"] {
            let column = (source["column"] as? NSNumber).map { ":\($0.intValue)" } ?? ""
            lines.append("Component source: \(file):\(line)\(column)")
        } else {
            lines.append("Component source: unavailable")
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
