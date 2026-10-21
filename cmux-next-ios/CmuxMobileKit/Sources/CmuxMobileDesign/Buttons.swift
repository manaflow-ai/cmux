#if os(iOS)
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Size of a CTA capsule (SPEC 4.1).
public struct CmuxMobileCapsuleSize: Sendable, Hashable {
    public let height: CGFloat
    public let fullWidth: Bool

    /// 52 pt, full width.
    public static let large = CmuxMobileCapsuleSize(height: 52, fullWidth: true)
    /// 40 pt, hugging its label with 20 pt padding.
    public static let inline = CmuxMobileCapsuleSize(height: 40, fullWidth: false)
}

/// Solid `accent` capsule with `onAccent` label. Pressed: 0.85 opacity and 0.98
/// scale; disabled: the same capsule at 40%; loading: spinner, width kept.
public struct PrimaryCapsule: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let size: CmuxMobileCapsuleSize
    let isLoading: Bool
    let action: () -> Void

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, size: CmuxMobileCapsuleSize = .large, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            CapsuleLabel(title: title, systemImage: systemImage, isLoading: isLoading, spinnerTint: theme.colors.onAccent.color)
        }
        .buttonStyle(CmuxMobileCapsuleStyle(size: size, kind: .primary))
        .allowsHitTesting(!isLoading)
    }
}

/// Glass capsule with `label` text.
public struct SecondaryCapsule: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let size: CmuxMobileCapsuleSize
    let action: () -> Void

    public init(_ title: LocalizedStringKey, systemImage: String? = nil, size: CmuxMobileCapsuleSize = .large, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            CapsuleLabel(title: title, systemImage: systemImage, isLoading: false, spinnerTint: theme.colors.label.color)
                .font(theme.type.cta)
                .foregroundStyle(theme.colors.label)
                .frame(maxWidth: size.fullWidth ? .infinity : nil)
                .padding(.horizontal, theme.metrics.ctaInlinePadding)
                .frame(height: size.height)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// A plain text button in `label`, `cta` font.
public struct TextCTA: View {
    let title: LocalizedStringKey
    let action: () -> Void

    public init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.type.cta)
                .foregroundStyle(theme.colors.label)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct CapsuleLabel: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let isLoading: Bool
    let spinnerTint: Color

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .opacity(isLoading ? 0 : 1)
            if isLoading {
                ProgressView().tint(spinnerTint)
            }
        }
    }
}

/// The capsule button style shared by primary CTAs and the sign-in buttons.
public struct CmuxMobileCapsuleStyle: ButtonStyle {
    /// Fill treatment.
    public struct Kind: Sendable, Hashable {
        public let id: Int
        /// `accent` fill, `onAccent` label.
        public static let primary = Kind(id: 0)
        /// `surface` fill in dark, `fill` in light, `label` text (sign-in providers).
        public static let provider = Kind(id: 1)
    }

    let size: CmuxMobileCapsuleSize
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CmuxMobileCapsuleSize, kind: Kind) {
        self.size = size
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(theme.type.cta)
            .foregroundStyle(foreground)
            .frame(maxWidth: size.fullWidth ? .infinity : nil)
            .multilineTextAlignment(.center)
            .padding(.horizontal, theme.metrics.ctaInlinePadding)
            // Grows with Dynamic Type instead of clipping its label.
            .padding(.vertical, size.fullWidth ? 12 : 8)
            .frame(minHeight: size.height)
            .background(background, in: .capsule)
            .contentShape(.capsule)
            // Disabled primary: the same capsule at 40%, still shaped.
            .opacity(kind == .primary && !isEnabled ? 0.4 : 1)
            .opacity(pressed ? 0.85 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(theme.motion.snap.animation, value: pressed)
    }

    private var foreground: AnyShapeStyle {
        guard isEnabled || kind == .primary else { return AnyShapeStyle(theme.colors.label3) }
        return kind == .primary ? AnyShapeStyle(theme.colors.onAccent) : AnyShapeStyle(theme.colors.label)
    }

    private var background: AnyShapeStyle {
        if kind == .primary {
            return AnyShapeStyle(theme.colors.accent)
        }
        return colorScheme == .dark ? AnyShapeStyle(theme.colors.surface) : AnyShapeStyle(theme.colors.fill)
    }
}
#endif
