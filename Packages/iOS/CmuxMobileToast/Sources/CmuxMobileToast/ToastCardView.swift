import CmuxMobileSupport
import SwiftUI

/// The toast's visual card: content-hugging Liquid Glass (material fallback),
/// a capsule for plain messages and a continuous rounded rect for
/// title+message pairs. Pure looks; lifetime and gestures live in the host.
struct ToastCardView: View {
    let toast: Toast
    /// Bumped on appear and on every coalescing re-present; bounces the icon.
    let iconBounceTrigger: Int
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isCompact: Bool { toast.title == nil }

    private var shape: AnyShape {
        isCompact
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol = toast.resolvedSystemImage {
                iconView(symbol)
            }
            textStack
            if let action = toast.action {
                actionButton(action)
            }
        }
        .padding(.leading, toast.resolvedSystemImage != nil ? 9 : 16)
        .padding(.trailing, toast.action != nil ? 9 : 16)
        .padding(.vertical, isCompact ? 9 : 11)
        .background { chrome }
        .contentShape(shape)
        .onTapGesture { dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(L10n.string("mobile.common.dismiss", defaultValue: "Dismiss"))) {
            dismiss()
        }
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityIdentifier("MobileToast")
    }

    @ViewBuilder
    private var chrome: some View {
        if reduceTransparency {
            shape
                .fill(solidBackgroundColor)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        } else {
            glassOrMaterial
        }
    }

    @ViewBuilder
    private var glassOrMaterial: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // Bare Liquid Glass is nearly transparent over busy content (a
            // terminal screen made toast text illegible), so the material
            // plate guarantees diffusion and the glass rides on top purely
            // for its rim and specular response.
            shape
                .fill(.regularMaterial)
                .overlay(Color.clear.glassEffect(.regular, in: shape))
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        } else {
            materialFallback
        }
        #else
        materialFallback
        #endif
    }

    private var materialFallback: some View {
        shape
            .fill(.regularMaterial)
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }

    private var solidBackgroundColor: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    private func iconView(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(toast.style.tint)
            .symbolEffect(.bounce, options: .nonRepeating, value: iconBounceTrigger)
            .frame(width: 26, height: 26)
            .background(Circle().fill(toast.style.tint.opacity(0.15)))
            .accessibilityHidden(true)
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title = toast.title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Text(toast.message)
                .font(isCompact ? .subheadline : .footnote)
                .foregroundStyle(isCompact ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(4)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func actionButton(_ action: Toast.Action) -> some View {
        Button(action.label) {
            action.handler()
            dismiss()
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(toast.style.actionTint)
        .accessibilityIdentifier("MobileToastActionButton")
    }
}

extension Toast.Style {
    var tint: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    /// Info actions use the app accent (a gray action button reads disabled);
    /// semantic styles keep their tint.
    var actionTint: Color? {
        switch self {
        case .info: return nil
        case .success, .warning, .failure: return tint
        }
    }
}
