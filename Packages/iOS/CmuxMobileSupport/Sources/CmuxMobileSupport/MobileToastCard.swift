import SwiftUI

struct MobileToastCard: View {
    let toast: MobileToast
    let dismiss: @MainActor () -> Void
    let performAction: @MainActor () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffsetY: CGFloat = 0

    private var upwardOffset: CGFloat {
        min(0, dragOffsetY)
    }

    private var dragProgress: CGFloat {
        min(1, abs(upwardOffset) / 72)
    }

    var body: some View {
        Group {
            if usesStackedLayout {
                stackedContent
            } else {
                horizontalContent
            }
        }
        .padding(.leading, toast.content.isCompact ? 10 : 12)
        .padding(.trailing, toast.content.isCompact ? 14 : 8)
        .padding(.vertical, toast.content.isCompact ? 8 : 10)
        .frame(maxWidth: toast.content.isCompact ? nil : 440)
        .modifier(MobileToastSurfaceModifier(isCompact: toast.content.isCompact))
        .contentShape(Rectangle())
        .offset(y: upwardOffset)
        .scaleEffect(reduceMotion ? 1 : 1 - (dragProgress * 0.025))
        .opacity(1 - (dragProgress * 0.45))
        .gesture(dismissGesture)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var usesStackedLayout: Bool {
        !toast.content.isCompact && dynamicTypeSize.isAccessibilitySize
    }

    private var horizontalContent: some View {
        HStack(alignment: .center, spacing: 10) {
            MobileToastIcon(toast: toast)
            toastCopy

            if toast.action != nil {
                actionButton
            }

            if !toast.content.isCompact {
                dismissButton
            }
        }
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                MobileToastIcon(toast: toast)
                Spacer(minLength: 0)
                dismissButton
            }

            toastCopy

            if toast.action != nil {
                HStack {
                    Spacer(minLength: 0)
                    actionButton
                }
            }
        }
    }

    private var toastCopy: some View {
        copy
            .frame(
                maxWidth: toast.content.isCompact ? nil : .infinity,
                alignment: .leading
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(toast.accessibilityIdentifier ?? "MobileToast")
            .accessibilityAction(.escape, dismiss)
            .accessibilityAction(
                named: Text(verbatim: L10n.string(
                    "mobile.common.dismiss",
                    defaultValue: "Dismiss"
                )),
                dismiss
            )
    }

    @ViewBuilder
    private var copy: some View {
        switch toast.content {
        case .compact(let message):
            message.text
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        case .detailed(let title, let message), .progress(let title, let message):
            VStack(alignment: .leading, spacing: 2) {
                title.text
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let message {
                    message.text
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private var actionButton: some View {
        Button(action: performAction) {
            toast.action?.label.text
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(minHeight: 44)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(L10n.string("mobile.common.dismiss", defaultValue: "Dismiss"))
        .accessibilityIdentifier("MobileToastDismissButton")
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    dragOffsetY = min(0, value.translation.height)
                }
            }
            .onEnded { value in
                let projectedTravel = min(
                    value.translation.height,
                    value.predictedEndTranslation.height
                )
                if projectedTravel < -44 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        dragOffsetY = 0
                    }
                }
            }
    }
}
