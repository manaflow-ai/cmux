import Foundation

/// Replaces CSS custom properties in an SVG document with concrete values.
///
/// Ondine's SVG declares its colours as custom properties on the root
/// element's `style` (`--_fg:var(--ondine-fg,#000)`) and its shapes read them
/// (`fill="var(--_fg)"`), which a browser resolves but CoreSVG does not: it
/// logs an error and drops the paint. This resolver substitutes every
/// `var(--name, fallback)` with the host's override for `--name`, else the
/// root's declaration, else the fallback; evaluates `color-mix(in srgb, ...)`
/// to a hex colour; and removes the custom declarations (and the browser sizing
/// ones, ``cssSizing``) from the root style.
/// The result has no `var(` left.
nonisolated struct SVGCustomPropertyResolver: Sendable {
    /// Nesting deeper than this resolves to nothing (a cycle such as `--a:var(--b);--b:var(--a)`).
    static let maxDepth = 16
    /// Root style declarations for a browser's layout (`max-width:100%;height:auto`). CoreSVG refuses
    /// `height:auto` ("Failed to parse height"); the `width` and `height` attributes size the image.
    static let cssSizing: Set<String> = ["width", "height", "max-width", "max-height", "min-width", "min-height"]

    /// `svg` with every custom property resolved.
    ///
    /// - Parameter overrides: values by property name (`"--ondine-fg": "#e1e1e1"`), winning over the
    ///   document's own declarations.
    func resolve(_ svg: String, overrides: [String: String]) -> String {
        var definitions = overrides
        var document = svg
        if let style = rootStyle(in: svg) {
            var kept: [String] = []
            var own: [String: String] = [:]
            for declaration in split(String(svg[style]), on: ";") {
                guard let colon = declaration.firstIndex(of: ":") else { continue }
                let name = declaration[..<colon].trimmingCharacters(in: .whitespaces)
                let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("--") {
                    own[name] = value
                } else if !Self.cssSizing.contains(name.lowercased()) {
                    kept.append(name + ":" + value)
                }
            }
            definitions.merge(own) { override, _ in override }
            document.replaceSubrange(style, with: kept.joined(separator: ";"))
        }
        return substitute(Substring(document), definitions, depth: 0)
    }

    /// The value range of the root `<svg>` element's `style` attribute.
    private func rootStyle(in svg: String) -> Range<String.Index>? {
        guard let open = svg.range(of: "<svg"), let end = svg[open.upperBound...].firstIndex(of: ">") else { return nil }
        guard let attribute = svg.range(of: " style=\"", range: open.upperBound..<end) else { return nil }
        guard let close = svg[attribute.upperBound..<end].firstIndex(of: "\"") else { return nil }
        return attribute.upperBound..<close
    }

    /// `text` with each `var(...)` and `color-mix(...)` replaced, in one pass.
    private func substitute(_ text: Substring, _ definitions: [String: String], depth: Int) -> String {
        guard depth <= Self.maxDepth else { return "" }
        guard text.contains("var(") || text.contains("color-mix(") else { return String(text) }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var rest = text
        while let hit = nextFunction(in: rest) {
            out += rest[..<hit.start]
            let inner = rest[hit.argumentsStart..<hit.close]
            if hit.isVar {
                let parts = split(String(inner), on: ",", limit: 2)
                let name = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let fallback = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                let value = definitions[name] ?? fallback
                out += substitute(Substring(value), definitions, depth: depth + 1)
            } else {
                let arguments = substitute(inner, definitions, depth: depth + 1)
                out += mix(arguments) ?? "color-mix(\(arguments))"
            }
            rest = rest[rest.index(after: hit.close)...]
        }
        out += rest
        return out
    }

    nonisolated private struct FunctionHit {
        var start: Substring.Index
        var argumentsStart: Substring.Index
        var close: Substring.Index
        var isVar: Bool
    }

    /// The first `var(` or `color-mix(` in `text` and its balanced closing parenthesis.
    private func nextFunction(in text: Substring) -> FunctionHit? {
        let v = text.range(of: "var(")
        let m = text.range(of: "color-mix(")
        guard let hit = [v, m].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        var depth = 1
        var index = hit.upperBound
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return FunctionHit(start: hit.lowerBound, argumentsStart: hit.upperBound, close: index, isVar: hit == v) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil // unbalanced: left as written
    }

    /// `color-mix(in srgb, A p%, B q%)`'s arguments as `#rrggbb`; nil for another form.
    private func mix(_ arguments: String) -> String? {
        let parts = split(arguments, on: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, parts[0].lowercased() == "in srgb" else { return nil }
        guard let (a, p) = colorStop(parts[1]), let (b, q) = colorStop(parts[2]) else { return nil }
        var wa = p, wb = q
        switch (wa, wb) {
        case (nil, nil): wa = 0.5; wb = 0.5
        case (let x?, nil): wb = 1 - x
        case (nil, let y?): wa = 1 - y
        default: break
        }
        let total = (wa ?? 0) + (wb ?? 0)
        guard total > 0 else { return nil }
        let fa = (wa ?? 0) / total, fb = (wb ?? 0) / total
        let rgb = (0..<3).map { a[$0] * fa + b[$0] * fb }
        return SVGColor(red: rgb[0], green: rgb[1], blue: rgb[2]).hex
    }

    /// A colour with an optional percentage (`#fff 20%`).
    private func colorStop(_ text: String) -> ([Double], Double?)? {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first, let color = SVGColor(css: first) else { return nil }
        let weight = words.dropFirst().first.flatMap { $0.hasSuffix("%") ? Double($0.dropLast()).map { $0 / 100 } : nil }
        return ([color.red, color.green, color.blue], weight)
    }

    /// `text` split at `separator` outside parentheses (at most `limit` pieces).
    private func split(_ text: String, on separator: Character, limit: Int = .max) -> [String] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        for c in text {
            if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
            if c == separator, depth == 0, pieces.count < limit - 1 {
                pieces.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        pieces.append(current)
        return pieces
    }
}
