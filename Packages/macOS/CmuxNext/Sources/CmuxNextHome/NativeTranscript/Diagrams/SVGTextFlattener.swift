import Foundation

/// Splits multi-line SVG text into one `<text>` element per line.
///
/// Ondine writes a label as `<text ...><tspan x="0" y="-24">Line</tspan>...</text>`.
/// CoreSVG ignores a `tspan`'s own `x` and `y`, so every line of a label drew
/// on one baseline (a class name over its first member). Each positioned
/// `tspan` becomes a `<text>` with the parent's attributes and the line's
/// position. A `text` whose content is anything else stays as written.
nonisolated struct SVGTextFlattener: Sendable {
    private static let textElement = try? NSRegularExpression(pattern: "<text((?:\\s[^>]*)?)>((?:<tspan[^>]*>[^<]*</tspan>)+)</text>")
    private static let span = try? NSRegularExpression(pattern: "<tspan([^>]*)>([^<]*)</tspan>")
    private static let position = try? NSRegularExpression(pattern: "\\s(x|y)=\"[^\"]*\"")

    /// `svg` with each label of positioned lines as separate `<text>` elements.
    func flatten(_ svg: String) -> String {
        guard svg.contains("<tspan"), let textElement = Self.textElement else { return svg }
        let ns = svg as NSString
        var out = ""
        var last = 0
        for match in textElement.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let attributes = ns.substring(with: match.range(at: 1))
            let content = ns.substring(with: match.range(at: 2))
            guard let lines = flattened(attributes: attributes, content: content) else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += lines
            last = match.range.location + match.range.length
        }
        guard last > 0 else { return svg }
        return out + ns.substring(from: last)
    }

    /// The lines as `<text>` elements, or nil when a line has no absolute position (or shifts by `dx`/`dy`).
    private func flattened(attributes: String, content: String) -> String? {
        guard let span = Self.span, let position = Self.position else { return nil }
        let parent = position.stringByReplacingMatches(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length),
                                                       withTemplate: "")
        let ns = content as NSString
        var out = ""
        for match in span.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let own = ns.substring(with: match.range(at: 1))
            guard own.contains(" x=\""), own.contains(" y=\""), !own.contains(" dx="), !own.contains(" dy=") else { return nil }
            out += "<text\(parent)\(own)>\(ns.substring(with: match.range(at: 2)))</text>"
        }
        return out
    }
}
