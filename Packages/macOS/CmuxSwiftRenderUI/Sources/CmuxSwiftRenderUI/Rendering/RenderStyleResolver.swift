import CmuxSwiftRender
import SwiftUI

/// Resolves captured modifier tokens into the effects used by rendering.
struct RenderStyleResolver {
    /// Creates a stateless resolver suitable for injection into a render tree.
    init() {}

    /// Strips source syntax decoration from a captured modifier token.
    func cleanToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.hasPrefix(".") {
            return String(raw.dropFirst())
        }
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// Resolves a captured color token after stripping source decoration.
    func color(_ rawToken: String?) -> Color? {
        dslColor(cleanToken(rawToken))
    }

    /// Whether a captured color token resolves to a nontransparent fill.
    func colorIsVisible(_ rawToken: String?) -> Bool {
        guard let token = cleanToken(rawToken), dslColor(token) != nil else {
            return false
        }
        if token.lowercased() == "clear" {
            return false
        }
        if token.hasPrefix("#"),
            token.count == 9,
            token.suffix(2).lowercased() == "00"
        {
            return false
        }
        return true
    }

    /// Applies the renderer's invalid-stop fallback to gradient colors.
    func gradient(
        _ tokens: [String]
    ) -> (colors: [Color], isVisible: Bool) {
        let resolved = tokens.compactMap {
            token -> (color: Color, isVisible: Bool)? in
            guard let color = color(token) else { return nil }
            return (color, colorIsVisible(token))
        }
        let colors = resolved.map(\.color)
        return (
            colors: colors.count >= 2
                ? colors
                : colors + [.clear, .clear],
            isVisible: resolved.contains(where: \.isVisible)
        )
    }

    /// Applies the renderer's secondary-color and one-point border defaults.
    func border(
        _ modifier: RenderModifier
    ) -> (color: Color, width: CGFloat, isVisible: Bool) {
        let rawToken = modifier.firstValue
        let resolvedColor = color(rawToken)
        let width =
            modifier.value("width")
            .map { cleanToken($0) ?? $0 }
            .flatMap(Double.init)
            ?? 1
        return (
            color: resolvedColor ?? .secondary,
            width: CGFloat(width),
            isVisible: width > 0
                && (resolvedColor == nil || colorIsVisible(rawToken))
        )
    }
}
