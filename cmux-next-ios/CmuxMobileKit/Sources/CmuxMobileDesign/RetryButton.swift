#if os(iOS)
import SwiftUI

/// The shared recovery action. Its work belongs to the visible control and is
/// cancelled when it leaves the screen; repeated taps cannot overlap a load.
///
/// `.capsule` (the default) is the SPEC 4.1 inline secondary capsule: 40 pt
/// tall in a 44 pt target, 20 pt side padding, `cta` type, always wider than
/// tall, so a short title like "Retry" never collapses into a circle.
/// `.inline` is a plain semibold text action for a row, pill or banner that
/// already draws its own background (a capsule inside a capsule reads as a
/// stray circle).
public struct RetryButton: View {
    /// How the button is drawn.
    public enum Style: Sendable, Hashable {
        /// A standalone secondary capsule (empty states, failure cards).
        case capsule
        /// Plain text inside a container that already has a background.
        case inline
    }

    let title: Text?
    let style: Style
    let action: @MainActor () async -> Void
    @State private var isRetrying = false

    /// `title` defaults to "Retry"; pass the surface's own wording ("Try Again").
    public init(_ title: LocalizedStringKey? = nil, style: Style = .capsule, action: @escaping @MainActor () async -> Void) {
        self.title = title.map { Text($0) }
        self.style = style
        self.action = action
    }

    /// The default title: "Retry".
    public static var defaultTitle: String {
        String(localized: "recovery.retry", defaultValue: "Retry", bundle: .module)
    }

    public var body: some View {
        styled(Button {
            isRetrying = true
        } label: {
            HStack(spacing: 8) {
                if isRetrying { ProgressView().controlSize(.small) }
                title ?? Text(verbatim: Self.defaultTitle)
            }
        })
        .disabled(isRetrying)
        .task(id: isRetrying) {
            guard isRetrying else { return }
            await action()
            isRetrying = false
        }
    }

    @ViewBuilder
    private func styled(_ button: some View) -> some View {
        switch style {
        case .capsule:
            button.buttonStyle(CmuxMobileCapsuleButtonStyle(.secondary, size: .inline))
        case .inline:
            button
                .buttonStyle(.plain)
                .font(CmuxMobileTheme.standard.type.meta.weight(.semibold))
                .foregroundStyle(CmuxMobileTheme.standard.colors.label)
                .frame(minHeight: CmuxMobileTheme.standard.metrics.glassButton)
                .contentShape(.rect)
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
