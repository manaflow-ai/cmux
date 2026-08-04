import CmuxSwiftRender

/// A modifier effect implemented by ``RenderNodeView``.
///
/// The interpreter intentionally preserves unknown modifier calls in the IR.
/// Keeping the renderer's supported set here lets validation ignore those
/// calls exactly as rendering does.
enum RenderedModifierKind: String {
    case font
    case bold
    case strikethrough
    case underline
    case italic
    case monospaced
    case monospacedDigit
    case fontWeight
    case fontDesign
    case multilineTextAlignment
    case textCase
    case truncationMode
    case foregroundColor
    case foregroundStyle
    case fill
    case tint
    case padding
    case background
    case overlay
    case mask
    case safeAreaInset
    case cornerRadius
    case opacity
    case lineLimit
    case frame
    case shadow
    case border
    case blur
    case offset
    case scaleEffect
    case rotationEffect
    case zIndex
    case brightness
    case contrast
    case saturation
    case grayscale
    case clipShape
    case imageScale
    case symbolRenderingMode
    case symbolVariant
    case contextMenu
    case help
    case keyboardShortcut
    case disabled
    case redacted
    case unredacted
    case accessibilityLabel
    case accessibilityHint
    case accessibilityValue
    case accessibilityHidden
    case scrollIndicators
    case scrollContentBackground
    case aspectRatio
    case scaledToFit
    case scaledToFill
    case clipped
    case fixedSize
    case layoutPriority

    // These effects are applied while the renderer still has the concrete
    // Image/Shape value, rather than in its generic modifier pass.
    case resizable
    case trim
    case stroke
    case strokeBorder
}

extension RenderModifier {
    var renderedKind: RenderedModifierKind? {
        RenderedModifierKind(rawValue: name)
    }

    func affectsRenderedOutput(of nodeKind: RenderNode.Kind) -> Bool {
        guard let renderedKind else { return false }
        switch renderedKind {
        case .resizable:
            return nodeKind == .image
        case .trim, .stroke, .strokeBorder:
            return nodeKind.isShape
        default:
            return true
        }
    }
}

private extension RenderNode.Kind {
    var isShape: Bool {
        switch self {
        case .rectangle,
             .roundedRectangle,
             .capsule,
             .circle,
             .ellipse,
             .unevenRoundedRectangle:
            return true
        default:
            return false
        }
    }
}
