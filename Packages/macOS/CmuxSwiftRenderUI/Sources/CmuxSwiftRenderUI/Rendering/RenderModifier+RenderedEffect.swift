import CmuxSwiftRender
import Foundation
import SwiftUI

extension RenderModifier {
    /// The modifier effect after applying the renderer's parsing, defaults,
    /// ignored arguments, and no-op rules.
    ///
    /// The returned modifier is a comparison value, not an instruction to
    /// render: its arguments are canonicalized so two source tokens that
    /// produce the same effect compare equally. `nil` means the renderer has
    /// no effect for this node.
    func normalizedRenderedEffect(
        on nodeKind: RenderNode.Kind,
        using styleResolver: RenderStyleResolver
    ) -> RenderModifier? {
        guard affectsRenderedOutput(of: nodeKind),
            let kind = renderedKind
        else {
            return nil
        }
        let token = styleResolver.cleanToken(firstValue)
        let normalizedDouble: (String?) -> Double? = {
            styleResolver.cleanToken($0).flatMap(Double.init)
        }
        let normalizedColor: (String?) -> String? = {
            self.normalizedColor($0, using: styleResolver)
        }
        let normalizedFrameAlignment: (String?) -> String = {
            self.normalizedFrameAlignment($0, using: styleResolver)
        }

        switch kind {
        case .font:
            guard let token,
                let normalized = normalizedFont(token)
            else {
                return nil
            }
            return normalizedEffect(kind, [renderedArg(normalized)])
        case .bold,
            .strikethrough,
            .underline,
            .italic,
            .monospaced,
            .monospacedDigit,
            .unredacted,
            .scaledToFit,
            .scaledToFill,
            .clipped,
            .fixedSize,
            .resizable:
            return normalizedEffect(kind)
        case .fontWeight:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedFontWeight(token))]
            )
        case .fontDesign:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedFontDesign(token))]
            )
        case .multilineTextAlignment:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedTextAlignment(token))]
            )
        case .textCase:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedTextCase(token))]
            )
        case .truncationMode:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedTruncationMode(token))]
            )
        case .foregroundColor, .foregroundStyle, .fill, .tint:
            guard let color = normalizedColor(firstValue) else { return nil }
            return normalizedEffect(kind, [renderedArg(color)])
        case .padding:
            let value =
                normalizedDouble(firstValue)
                .map(renderedDouble)
                ?? "default"
            return normalizedEffect(kind, [renderedArg(value)])
        case .background, .overlay:
            if !children.isEmpty {
                return normalizedEffect(
                    kind,
                    [
                        renderedArg(
                            normalizedFrameAlignment(value("alignment")),
                            label: "alignment"
                        )
                    ],
                    children: children
                )
            }
            guard let color = normalizedColor(firstValue) else { return nil }
            return normalizedEffect(kind, [renderedArg(color)])
        case .mask:
            guard !children.isEmpty else { return nil }
            return normalizedEffect(kind, children: children)
        case .safeAreaInset:
            guard !children.isEmpty else { return nil }
            let edge =
                styleResolver.cleanToken(value("edge")) == "top"
                ? "top"
                : "bottom"
            return normalizedEffect(
                kind,
                [renderedArg(edge, label: "edge")],
                children: children
            )
        case .cornerRadius:
            guard let value = normalizedDouble(firstValue) else { return nil }
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .opacity:
            guard let value = normalizedDouble(firstValue) else {
                return nil
            }
            let renderedValue = min(max(value, 0), 1)
            guard renderedValue != 1 else {
                return nil
            }
            return normalizedEffect(
                kind,
                [renderedArg(renderedDouble(renderedValue))]
            )
        case .lineLimit:
            guard let value = token.flatMap(Int.init) else { return nil }
            return normalizedEffect(kind, [renderedArg(String(value))])
        case .frame:
            var dimensions: [ModifierArg] = []
            for label in [
                "minWidth",
                "maxWidth",
                "minHeight",
                "maxHeight",
                "width",
                "height",
            ] {
                guard let value = normalizedFrameDimension(self.value(label))
                else { continue }
                dimensions.append(renderedArg(value, label: label))
            }
            guard !dimensions.isEmpty else { return nil }
            dimensions.append(
                renderedArg(
                    normalizedFrameAlignment(value("alignment")),
                    label: "alignment"
                )
            )
            return normalizedEffect(kind, dimensions)
        case .shadow:
            let radius =
                normalizedDouble(value("radius"))
                ?? normalizedDouble(firstValue)
                ?? 4
            let color =
                normalizedColor(value("color"))
                ?? "black@0.33"
            let x = normalizedDouble(value("x")) ?? 0
            let y = normalizedDouble(value("y")) ?? 0
            return normalizedEffect(
                kind,
                [
                    renderedArg(color, label: "color"),
                    renderedArg(renderedDouble(radius), label: "radius"),
                    renderedArg(renderedDouble(x), label: "x"),
                    renderedArg(renderedDouble(y), label: "y"),
                ]
            )
        case .border:
            let color = normalizedColor(firstValue) ?? "secondary"
            let width = normalizedDouble(value("width")) ?? 1
            return normalizedEffect(
                kind,
                [
                    renderedArg(color),
                    renderedArg(renderedDouble(width), label: "width"),
                ]
            )
        case .blur:
            let radius =
                normalizedDouble(value("radius"))
                ?? normalizedDouble(firstValue)
                ?? 0
            guard radius != 0 else { return nil }
            return normalizedEffect(
                kind,
                [renderedArg(renderedDouble(radius), label: "radius")]
            )
        case .offset:
            let x = normalizedDouble(value("x")) ?? 0
            let y = normalizedDouble(value("y")) ?? 0
            guard x != 0 || y != 0 else { return nil }
            return normalizedEffect(
                kind,
                [
                    renderedArg(renderedDouble(x), label: "x"),
                    renderedArg(renderedDouble(y), label: "y"),
                ]
            )
        case .scaleEffect:
            guard let value = normalizedDouble(firstValue),
                value != 1
            else {
                return nil
            }
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .rotationEffect:
            let value = renderedAngleDegrees(token) ?? 0
            guard value != 0 else { return nil }
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .zIndex:
            guard let value = normalizedDouble(firstValue),
                value != 0
            else {
                return nil
            }
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .brightness:
            let value = normalizedDouble(firstValue) ?? 0
            guard value != 0 else { return nil }
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .contrast:
            let value = normalizedDouble(firstValue) ?? 1
            guard value != 1 else { return nil }
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .saturation:
            let value = normalizedDouble(firstValue) ?? 1
            guard value != 1 else { return nil }
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .grayscale:
            let value = normalizedDouble(firstValue) ?? 0
            guard value != 0 else { return nil }
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .clipShape:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedClipShape(token))]
            )
        case .imageScale:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedImageScale(token))]
            )
        case .symbolRenderingMode:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedSymbolRenderingMode(token))]
            )
        case .symbolVariant:
            return normalizedEffect(
                kind,
                [renderedArg(normalizedSymbolVariant(token))]
            )
        case .contextMenu:
            guard !children.isEmpty else { return nil }
            return normalizedEffect(kind, children: children)
        case .help:
            guard let token else { return nil }
            return normalizedEffect(kind, [renderedArg(token)])
        case .keyboardShortcut:
            guard let key = normalizedKeyEquivalent(token) else { return nil }
            return normalizedEffect(
                kind,
                [
                    renderedArg(key),
                    renderedArg(
                        normalizedEventModifiers(value("modifiers")),
                        label: "modifiers"
                    ),
                ]
            )
        case .disabled:
            return normalizedEffect(
                kind,
                [renderedArg(token == "true" ? "true" : "false")]
            )
        case .redacted:
            let reason = styleResolver.cleanToken(value("reason")) ?? token
            return normalizedEffect(
                kind,
                [renderedArg(reason == "invalidated" ? "invalidated" : "placeholder")]
            )
        case .accessibilityLabel,
            .accessibilityHint,
            .accessibilityValue:
            return normalizedEffect(kind, [renderedArg(token ?? "")])
        case .accessibilityHidden:
            return normalizedEffect(
                kind,
                [renderedArg(token == "false" ? "false" : "true")]
            )
        case .scrollIndicators:
            let visibility =
                token == "hidden" || token == "never"
                ? "hidden"
                : "visible"
            return normalizedEffect(kind, [renderedArg(visibility)])
        case .scrollContentBackground:
            return normalizedEffect(
                kind,
                [renderedArg(token == "hidden" ? "hidden" : "visible")]
            )
        case .aspectRatio:
            let ratio = normalizedDouble(firstValue)
                .flatMap { $0 > 0 ? $0 : nil }
            let mode =
                styleResolver.cleanToken(value("contentMode")) == "fill"
                ? "fill"
                : "fit"
            return normalizedEffect(
                kind,
                [
                    renderedArg(ratio.map(renderedDouble) ?? "automatic"),
                    renderedArg(mode, label: "contentMode"),
                ]
            )
        case .layoutPriority:
            let value = normalizedDouble(firstValue) ?? 0
            return normalizedEffect(kind, [renderedArg(renderedDouble(value))])
        case .trim:
            let from = normalizedDouble(value("from")) ?? 0
            let to = normalizedDouble(value("to")) ?? 1
            return normalizedEffect(
                kind,
                [
                    renderedArg(renderedDouble(from), label: "from"),
                    renderedArg(renderedDouble(to), label: "to"),
                ]
            )
        case .stroke, .strokeBorder:
            let color = normalizedColor(firstValue) ?? "secondary"
            let width = normalizedDouble(value("lineWidth")) ?? 1
            return normalizedEffect(
                kind,
                [
                    renderedArg(color),
                    renderedArg(renderedDouble(width), label: "lineWidth"),
                ]
            )
        }
    }
}

extension RenderModifier {
    /// Converts a captured degrees-or-radians token to rendered degrees.
    private func renderedAngleDegrees(_ token: String?) -> Double? {
        guard let token else { return nil }
        if let open = token.firstIndex(of: "("),
            let close = token.lastIndex(of: ")")
        {
            let inner = String(token[token.index(after: open)..<close])
            guard
                let value = Double(
                    inner.trimmingCharacters(in: .whitespaces)
                )
            else {
                return nil
            }
            return token.contains("radians") ? value * 180 / .pi : value
        }
        return Double(token)
    }

    /// Builds a canonical modifier used for rendering and output comparison.
    private func normalizedEffect(
        _ kind: RenderedModifierKind,
        _ args: [ModifierArg] = [],
        children: [RenderNode] = []
    ) -> RenderModifier {
        RenderModifier(name: kind.rawValue, args: args, children: children)
    }

    /// Builds one canonical modifier argument.
    private func renderedArg(
        _ value: String,
        label: String? = nil
    ) -> ModifierArg {
        ModifierArg(label: label, value: value)
    }

    /// Produces a stable textual representation of a rendered number.
    private func renderedDouble(_ value: Double) -> String {
        value == 0 ? "0" : String(value)
    }

    /// Canonicalizes a color token only when the renderer can resolve it.
    private func normalizedColor(
        _ rawValue: String?,
        using styleResolver: RenderStyleResolver
    ) -> String? {
        guard let token = styleResolver.cleanToken(rawValue),
            dslColor(token) != nil
        else {
            return nil
        }
        switch token.lowercased() {
        case "accentcolor":
            return "accent"
        case "grey":
            return "gray"
        default:
            return token.lowercased()
        }
    }

    /// Canonicalizes a font-weight token to the renderer's supported set.
    private func normalizedFontWeight(_ token: String?) -> String {
        switch token?.lowercased() {
        case "ultralight": return "ultralight"
        case "thin": return "thin"
        case "light": return "light"
        case "regular": return "regular"
        case "medium": return "medium"
        case "semibold": return "semibold"
        case "bold": return "bold"
        case "heavy": return "heavy"
        case "black": return "black"
        default: return "none"
        }
    }

    /// Converts a named or system font token to one canonical system font.
    private func normalizedFont(_ token: String) -> String? {
        let styleNames = [
            "largeTitle",
            "title3",
            "title2",
            "title",
            "headline",
            "subheadline",
            "body",
            "callout",
            "footnote",
            "caption2",
            "caption",
        ]

        var baseSize: CGFloat = 13
        var weight: String?
        var monospaced = false
        var matchedStyle: String?
        var parsedSize: Double?
        if token.hasPrefix("system") {
            monospaced = token.contains("monospaced")
            if let range = token.range(of: "weight:") {
                let rawWeight = token[range.upperBound...]
                    .drop(while: { $0 == " " || $0 == "." })
                    .prefix(while: { $0.isLetter })
                let resolvedWeight = normalizedFontWeight(String(rawWeight))
                weight = resolvedWeight == "none" ? nil : resolvedWeight
            }
            if let range = token.range(of: "size:") {
                let digits = token[range.upperBound...]
                    .drop(while: { $0 == " " })
                    .prefix(while: { $0.isNumber || $0 == "." })
                parsedSize = Double(String(digits))
                if let value = parsedSize {
                    baseSize = CGFloat(value)
                }
            }
            if parsedSize == nil,
                let style = styleNames.first(where: token.contains),
                let spec = dslFontSpec(named: style, size: nil)
            {
                baseSize = spec.baseSize
                matchedStyle = style
            }
        } else {
            guard let spec = dslFontSpec(named: token, size: nil) else {
                return nil
            }
            baseSize = spec.baseSize
            matchedStyle = token
        }
        if weight == nil, matchedStyle?.lowercased() == "headline" {
            weight = "semibold"
        }

        var normalized = "system(size: \(renderedDouble(Double(baseSize)))"
        if let weight {
            normalized += ", weight: .\(weight)"
        }
        if monospaced {
            normalized += ", design: .monospaced"
        }
        normalized += ")"
        return normalized
    }

    /// Canonicalizes a font-design token, including the renderer's default.
    private func normalizedFontDesign(_ token: String?) -> String {
        switch token?.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        ) {
        case "monospaced": return "monospaced"
        case "rounded": return "rounded"
        case "serif": return "serif"
        case "default": return "default"
        default: return "none"
        }
    }

    /// Canonicalizes a text alignment, defaulting to leading.
    private func normalizedTextAlignment(_ token: String?) -> String {
        switch token?.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        ) {
        case "center": return "center"
        case "trailing": return "trailing"
        default: return "leading"
        }
    }

    /// Canonicalizes a text-case token, including the no-transform default.
    private func normalizedTextCase(_ token: String?) -> String {
        switch token?.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        ) {
        case "uppercase": return "uppercase"
        case "lowercase": return "lowercase"
        default: return "none"
        }
    }

    /// Canonicalizes a truncation mode, defaulting to tail.
    private func normalizedTruncationMode(_ token: String?) -> String {
        switch token?.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        ) {
        case "head": return "head"
        case "middle": return "middle"
        default: return "tail"
        }
    }

    /// Canonicalizes a finite frame dimension or the infinity sentinel.
    private func normalizedFrameDimension(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        if rawValue == ".infinity" || rawValue == "infinity" {
            return "infinity"
        }
        return Double(rawValue).map(renderedDouble)
    }

    /// Canonicalizes frame alignment, defaulting to center.
    private func normalizedFrameAlignment(
        _ rawValue: String?,
        using styleResolver: RenderStyleResolver
    ) -> String {
        switch styleResolver.cleanToken(rawValue) {
        case "leading": return "leading"
        case "trailing": return "trailing"
        case "top": return "top"
        case "bottom": return "bottom"
        case "topLeading": return "topLeading"
        case "topTrailing": return "topTrailing"
        case "bottomLeading": return "bottomLeading"
        case "bottomTrailing": return "bottomTrailing"
        default: return "center"
        }
    }

    /// Canonicalizes a clip-shape token to the renderer's supported shapes.
    private func normalizedClipShape(_ token: String?) -> String {
        switch token?.lowercased() {
        case let token? where token.hasPrefix("circle"): return "circle"
        case let token? where token.hasPrefix("capsule"): return "capsule"
        case let token? where token.hasPrefix("ellipse"): return "ellipse"
        case let token? where token.hasPrefix("rectangle"): return "rectangle"
        default: return "roundedRectangle"
        }
    }

    /// Canonicalizes image scale, defaulting to medium.
    private func normalizedImageScale(_ token: String?) -> String {
        switch token?.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        ) {
        case "small": return "small"
        case "large": return "large"
        default: return "medium"
        }
    }

    /// Canonicalizes symbol rendering mode, defaulting to monochrome.
    private func normalizedSymbolRenderingMode(_ token: String?) -> String {
        switch token?.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        ) {
        case "hierarchical": return "hierarchical"
        case "multicolor": return "multicolor"
        case "palette": return "palette"
        default: return "monochrome"
        }
    }

    /// Canonicalizes a symbol variant, including the no-variant default.
    private func normalizedSymbolVariant(_ token: String?) -> String {
        switch token?.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        ) {
        case "fill": return "fill"
        case "circle": return "circle"
        case "square": return "square"
        case "slash": return "slash"
        default: return "none"
        }
    }

    /// Canonicalizes a supported keyboard-shortcut key.
    private func normalizedKeyEquivalent(_ token: String?) -> String? {
        guard dslKeyEquivalent(token) != nil,
            let raw = token?.trimmingCharacters(
                in: CharacterSet(charactersIn: ".\" ")
            ),
            let first = raw.first
        else {
            return nil
        }
        switch raw.lowercased() {
        case "return": return "return"
        case "escape": return "escape"
        case "space": return "space"
        case "tab": return "tab"
        case "delete": return "delete"
        case "uparrow": return "upArrow"
        case "downarrow": return "downArrow"
        case "leftarrow": return "leftArrow"
        case "rightarrow": return "rightArrow"
        default: return String(first)
        }
    }

    /// Produces a stable ordering for keyboard event modifiers.
    private func normalizedEventModifiers(_ source: String?) -> String {
        guard let source = source?.lowercased() else { return "" }
        return [
            "command",
            "shift",
            "option",
            "control",
        ].filter(source.contains).joined(separator: ",")
    }
}
