import CmuxFoundation
import SwiftUI

/// Resolves a font token (or explicit size) to a magnification-aware font spec.
func dslFontSpec(
    named token: String?,
    size: Double?,
    weight: Font.Weight? = nil,
    design: Font.Design = .default,
    family: String? = nil
) -> DSLFontSpec? {
    let normalizedFamily = CmuxFontFamily.normalizedName(family)
    func make(_ baseSize: CGFloat, defaultWeight: Font.Weight? = nil) -> DSLFontSpec {
        DSLFontSpec(
            baseSize: baseSize,
            weight: weight ?? defaultWeight,
            design: design,
            family: normalizedFamily
        )
    }
    if let size { return make(CGFloat(size)) }
    guard let token else { return normalizedFamily == nil ? nil : make(13) }
    switch token.lowercased() {
    case "largetitle": return make(26)
    case "title": return make(22)
    case "title2": return make(17)
    case "title3": return make(15)
    case "headline": return make(13, defaultWeight: .semibold)
    case "subheadline": return make(11)
    case "body": return make(13)
    case "callout": return make(12)
    case "footnote": return make(10)
    case "caption": return make(10)
    case "caption2": return make(9)
    default: return nil
    }
}

@MainActor
func dslFontSpec(from node: SceneNode) -> DSLFontSpec? {
    let weight = dslFontWeight(node.string("weight"))
    return dslFontSpec(
        named: node.string("font") ?? (weight == nil ? nil : "body"),
        size: node.props["font"]?.doubleValue,
        weight: weight,
        family: node.string("family")
    )
}
