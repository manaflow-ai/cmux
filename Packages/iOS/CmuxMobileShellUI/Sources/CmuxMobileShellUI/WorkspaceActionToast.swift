import CmuxMobileSupport
import SwiftUI

/// Bottom-mounted dismissible toast for workspace-action failures.
struct WorkspaceActionToast: View {
    static let autoDismissDelay: Duration = .seconds(6)

    let content: WorkspaceActionToastContent
    var clock: any Clock<Duration> = ContinuousClock()
    let dismiss: () -> Void

    @State private var toastHeight: CGFloat = 1
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            Text(content.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("mobile.common.dismiss", defaultValue: "Dismiss"))
            .accessibilityIdentifier("MobileWorkspaceActionToastDismissButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.24), lineWidth: 0.5)
        }
        .contentShape(Capsule())
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { toastHeight = max(1, proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in
                        toastHeight = max(1, height)
                    }
            }
        }
        .offset(y: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 4)
                .updating($dragOffset) { value, state, _ in
                    state = max(0, value.translation.height)
                }
                .onEnded { value in
                    let downwardTravel = max(0, value.translation.height)
                    if downwardTravel > toastHeight * 0.5 {
                        withAnimation(.snappy(duration: 0.2)) {
                            dismiss()
                        }
                    }
                }
        )
        .task(id: content.id) {
            // Intended bounded auto-dismiss, driven by an injected clock so tests
            // can advance time without wall-clock sleeps.
            try? await clock.sleep(for: Self.autoDismissDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.snappy(duration: 0.2)) {
                    dismiss()
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: dragOffset)
    }
}
