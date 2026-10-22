#if os(iOS)
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// The floating Liquid Glass circle used outside toolbars (SPEC 4.1). Inside a
/// toolbar use a plain `Button` with a symbol: the system draws the glass.
public struct GlassCircleButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    var size: CGFloat
    let action: () -> Void

    public init(_ systemImage: String, accessibilityLabel: LocalizedStringKey, size: CGFloat = 44, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: theme.metrics.glassSymbol, weight: .regular))
                .foregroundStyle(theme.colors.label)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A team avatar (SPEC 3.3): a continuous rounded square in the team color
/// with the team's glyph centered. `emoji` is the stored glyph: nil draws the
/// name's first letter, `""` draws nothing (color only), and any other value is
/// the one character the user typed: an emoji at emoji size, or a letter,
/// digit or symbol in white like the initial.
///
/// `transparent` (only meaningful with a typed character) drops the fill: the
/// character sits on whatever is behind the badge, inside a hairline outline
/// that keeps the badge's shape readable in light and dark, and a letter,
/// digit or symbol is drawn in `label` instead of white.
public struct TeamAvatar: View {
    let name: String
    let colorHex: String?
    let emoji: String?
    var size: CGFloat
    let transparent: Bool

    public init(name: String, colorHex: String?, emoji: String?, size: CGFloat = 36, transparent: Bool = false) {
        self.name = name
        self.colorHex = colorHex
        self.emoji = emoji
        self.size = size
        self.transparent = transparent
    }

    public var body: some View {
        let radius = size * (theme.metrics.teamAvatarRadius / theme.metrics.teamAvatar)
        // Transparent only over a typed character: never an empty badge.
        let transparent = transparent && emoji?.isEmpty == false
        ZStack {
            if transparent {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.colors.separator, lineWidth: 1)
            } else if let colorHex {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.colors.team(colorHex))
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.colors.fill)
            }
            switch emoji {
            case nil:
                letter(String(name.prefix(1)).uppercased())
            case let glyph? where glyph.isEmpty:
                EmptyView()
            case let glyph? where Self.isEmoji(glyph):
                Text(verbatim: glyph).font(.system(size: size * 0.61))
            case let glyph?:
                letter(glyph)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func letter(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(transparent && emoji?.isEmpty == false ? AnyShapeStyle(theme.colors.label) : AnyShapeStyle(.white))
            .minimumScaleFactor(0.5)
    }

    /// True for a grapheme that renders as color emoji (including keycaps,
    /// flags and ZWJ sequences), false for letters, digits and text symbols.
    static func isEmoji(_ glyph: String) -> Bool {
        guard let character = glyph.first else { return false }
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        // Text-default emoji (e.g. "❤") become emoji with VS16 or in a sequence.
        return scalars.count > 1 && scalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F })
    }
}

/// The cmux chevron mark (from `web/public/cmux-icon.svg`), drawn as a shape so
/// it tints with `label`.
public struct CmuxMark: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        // Source path in a 256 box: M91 65 L179 128 L91 191 L91 151 L139 128 L91 105 Z.
        // Normalized to the chevron's own bounds (x 91...179, y 65...191) and centered.
        let w: CGFloat = 88, h: CGFloat = 126
        let scale = min(rect.width / w, rect.height / h)
        let ox = rect.midX - w * scale / 2, oy = rect.midY - h * scale / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + (x - 91) * scale, y: oy + (y - 65) * scale) }
        var path = Path()
        path.move(to: p(91, 65))
        path.addLine(to: p(179, 128))
        path.addLine(to: p(91, 191))
        path.addLine(to: p(91, 151))
        path.addLine(to: p(139, 128))
        path.addLine(to: p(91, 105))
        path.closeSubpath()
        return path
    }
}
#endif
