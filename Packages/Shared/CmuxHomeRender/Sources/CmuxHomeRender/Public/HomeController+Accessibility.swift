import CmuxHomeCore
import CoreGraphics

extension HomeController {
    /// The visible transcript rows, top to bottom, then the compose field.
    /// Hosts mirror these as accessibility elements (NSAccessibilityElement,
    /// UIAccessibilityElement) and refresh them on `onAccessibilityChange`.
    public func accessibilityItems() -> [HomeAXItem] {
        let names = Dictionary((summary?.participants ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let authors = Dictionary(items.map { ($0.key.rawValue, $0.author) }, uniquingKeysWith: { a, _ in a })
        let shown = scene.visible.values.compactMap { r in scene.visibleIndex[ObjectIdentifier(r)] }.sorted()
        var out: [HomeAXItem] = []
        for i in shown where i < scene.model.count {
            let row = scene.model.rows[i]
            guard !row.ghost else { continue }
            let spec = row.spec
            let top = scene.windowY(contentY: scene.layout.contentTop(i))
            guard top + spec.height > scene.topInset, top < scene.anchorY else { continue }
            var frame = CGRect(x: 0, y: top, width: scene.size.width, height: spec.height)
            let label: String, value: String
            switch spec.kind {
            case .part(let p):
                let body = RowArt.bodyRect(spec, metrics: scene.metrics)
                frame = CGRect(x: body.minX, y: top, width: body.width, height: body.height)
                label = p.text.text
                let author = Self.itemKey(of: spec.key).flatMap { authors[$0] }
                if author == me {
                    value = HomeStrings.fromMe
                } else {
                    value = author.map { HomeStrings.from(names[$0] ?? $0.rawValue) } ?? ""
                }
            case .separator(let bold, let rest): label = bold + " " + rest; value = ""
            case .receipt(let text), .failedLabel(let text): label = text; value = ""
            case .unsent(let outgoing): label = outgoing ? HomeStrings.unsentMine : HomeStrings.unsentTheirs; value = ""
            case .typing: label = HomeStrings.typing; value = ""
            }
            out.append(HomeAXItem(id: spec.key, role: .staticText, label: label, value: value, frame: frame))
        }
        out.append(HomeAXItem(id: "compose", role: .textArea, label: HomeStrings.composeLabel, value: draft, frame: fieldRect))
        return out
    }

    /// The item key inside a row key ("kind:<item key>[:part]").
    static func itemKey(of rowKey: String) -> String? {
        guard let colon = rowKey.firstIndex(of: ":") else { return nil }
        var rest = rowKey[rowKey.index(after: colon)...]
        if rowKey.hasPrefix("part:"), let last = rest.lastIndex(of: ":") { rest = rest[..<last] }
        return String(rest)
    }
}
