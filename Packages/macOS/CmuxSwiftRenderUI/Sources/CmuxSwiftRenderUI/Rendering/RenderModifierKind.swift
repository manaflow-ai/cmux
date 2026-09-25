/// Modifier names understood by the native interpreter renderer.
/// The exhaustive rendering switch also defines what validation can accept.
enum RenderModifierKind: String {
    case font, bold, strikethrough, underline, italic
    case monospaced, monospacedDigit, fontWeight, fontDesign, multilineTextAlignment
    case textCase, truncationMode, foregroundColor, foregroundStyle, fill
    case tint, padding, background, overlay, mask
    case safeAreaInset, cornerRadius, opacity, lineLimit, frame
    case shadow, border, blur, offset, scaleEffect
    case rotationEffect, zIndex, brightness, contrast, saturation
    case grayscale, clipShape, imageScale, symbolRenderingMode, symbolVariant
    case contextMenu, help, keyboardShortcut, disabled, redacted
    case unredacted, accessibilityLabel, accessibilityHint, accessibilityValue, accessibilityHidden
    case scrollIndicators, scrollContentBackground, aspectRatio, scaledToFit, scaledToFill
    case clipped, fixedSize, layoutPriority, resizable, trim
    case stroke, strokeBorder
}
