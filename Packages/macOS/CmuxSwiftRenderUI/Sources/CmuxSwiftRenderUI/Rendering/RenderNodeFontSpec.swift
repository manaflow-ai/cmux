import CmuxSwiftRender
import SwiftUI

/// Resolves the interpreter's raw `.font(...)` token into the shared font
/// specification. Kept outside ``RenderNodeView`` so the retained view stays
/// below the tracked file-size budget as font syntax grows.
func dslFontSpec(from token: String?) -> DSLFontSpec? {
    guard let token else { return nil }
    let cleaned = token.hasPrefix(".") ? String(token.dropFirst()) : token
    if cleaned.hasPrefix("custom") {
        let family = quotedArgument(in: cleaned)
        let size = numericArgument(named: "size", in: cleaned)
        return dslFontSpec(named: nil, size: size, family: family)
    }
    guard cleaned.hasPrefix("system") else {
        return dslFontSpec(named: cleaned, size: nil)
    }
    let design = dslFontDesign(namedArgument(named: "design", in: cleaned)) ?? .default
    let weight = dslFontWeight(in: cleaned)
    if let size = numericArgument(named: "size", in: cleaned) {
        return dslFontSpec(named: nil, size: size, weight: weight, design: design)
    }
    let styleNames = [
        "largeTitle", "title3", "title2", "title",
        "headline", "subheadline", "body", "callout",
        "footnote", "caption2", "caption",
    ]
    for name in styleNames where cleaned.contains(name) {
        return dslFontSpec(named: name, size: nil, weight: weight, design: design)
    }
    return dslFontSpec(named: nil, size: 13, weight: weight, design: design)
}

private func quotedArgument(in token: String) -> String? {
    guard let start = token.firstIndex(of: "\""),
          let end = token[token.index(after: start)...].firstIndex(of: "\"") else { return nil }
    return String(token[token.index(after: start)..<end])
}

private func numericArgument(named name: String, in token: String) -> Double? {
    guard let range = token.range(of: "\(name):") else { return nil }
    let digits = token[range.upperBound...]
        .drop(while: { $0 == " " })
        .prefix(while: { $0.isNumber || $0 == "." })
    return Double(digits)
}

private func namedArgument(named name: String, in token: String) -> String? {
    guard let range = token.range(of: "\(name):") else { return nil }
    let value = token[range.upperBound...]
        .drop(while: { $0 == " " })
        .prefix(while: { $0 != "," && $0 != ")" })
    return String(value).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func dslFontWeight(in token: String) -> Font.Weight? {
    guard let range = token.range(of: "weight:") else { return nil }
    let rawWeight = token[range.upperBound...]
        .drop(while: { $0 == " " || $0 == "." })
        .prefix(while: { $0.isLetter })
    return dslFontWeight(String(rawWeight))
}
