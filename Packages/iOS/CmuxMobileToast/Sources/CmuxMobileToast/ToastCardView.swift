import CmuxMobileSupport
import SwiftUI

/// The toast's visual card: a quiet, content-hugging system surface. Pure
/// looks; lifetime and gestures live in the host.
struct ToastCardView: View {
    let toast: Toast
    let dismiss: () -> Void

    private var isCompact: Bool { toast.title == nil }

    private var shape: AnyShape {
        isCompact
            ? AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .background {
            shape
                .fill(backgroundColor)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .contentShape(shape)
        .onTapGesture { dismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(L10n.string("mobile.common.dismiss", defaultValue: "Dismiss"))) {
            dismiss()
        }
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityIdentifier("MobileToast")
    }

    private var backgroundColor: Color {
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
        .buttonBorderShape(.roundedRectangle(radius: 8))
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
