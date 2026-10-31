#if os(iOS)
import SwiftUI

/// The shared recovery action. Its work belongs to the visible control and is
/// cancelled when it leaves the screen; repeated taps cannot overlap a load.
public struct RetryButton: View {
    let action: @MainActor () async -> Void
    @State private var isRetrying = false

    public init(action: @escaping @MainActor () async -> Void) {
        self.action = action
    }

    public var body: some View {
        Button {
            isRetrying = true
        } label: {
            HStack {
                if isRetrying { ProgressView().controlSize(.small) }
                Text(String(localized: "recovery.retry", defaultValue: "Retry", bundle: .module))
            }
            .font(CmuxMobileTheme.standard.type.meta.weight(.semibold))
            .frame(minHeight: CmuxMobileTheme.standard.metrics.glassButton)
        }
        .buttonStyle(.glass)
        .tint(CmuxMobileTheme.standard.colors.label.color)
        .disabled(isRetrying)
        .task(id: isRetrying) {
            guard isRetrying else { return }
            await action()
            isRetrying = false
        }
    }
}
/// Short recovery copy shared by the Home surfaces.
public enum RecoveryMessage {
    case home, conversation

    public var text: String {
        switch self {
        case .home: String(localized: "recovery.home", defaultValue: "Couldn't load this Mac's Home.", bundle: .module)
        case .conversation: String(localized: "recovery.conversation", defaultValue: "Couldn't load this conversation.", bundle: .module)
        }
    }
}
#endif
