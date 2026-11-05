#if os(iOS)
import CmuxConversationCore
import CmuxMobileDesign
import SwiftUI

/// Messages queued before the shared transcript has a sender. Keep these in
/// the host's reserved status area until the session hands them to the store.
/// The list scrolls independently so a long draft cannot cover the composer.
struct ChiefOutboxView: View {
    let session: ChiefSession
    var resized: () -> Void
    private let theme = CmuxMobileTheme.standard
    @State private var contentHeight: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        if !session.outbox.isEmpty {
            VStack(alignment: .trailing) {
                ScrollView {
                    VStack(alignment: .trailing, spacing: theme.metrics.selectedRowInset) {
                        ForEach(Array(session.outbox.enumerated()), id: \.offset) { _, message in
                            VStack(alignment: .trailing) {
                                VStack(alignment: .leading) {
                                    if !message.text.isEmpty { Text(message.text) }
                                    if !message.images.isEmpty {
                                        Label {
                                            HStack { Text(String(localized: "mobile.chief.outbox.photos", defaultValue: "Photos", bundle: .module)); Text(message.images.count.formatted()) }
                                        } icon: { Image(systemName: "photo") }
                                    }
                                }
                                .font(theme.type.body)
                                .padding(theme.metrics.composerSideMargin)
                                .background(Color.cmuxMobileBubble, in: .rect(cornerRadius: theme.metrics.cardRadius))
                                Text(String(localized: "mobile.chief.outbox.waiting", defaultValue: "Sends when connected", bundle: .module))
                                    .font(theme.type.meta)
                                    .foregroundStyle(theme.colors.label2)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, theme.metrics.settingsRowHeight),
                                   verticalSizeClass == .compact ? theme.metrics.settingsRowHeight : theme.metrics.composerMinHeight * 2))
                .scrollBounceBehavior(.basedOnSize)
                HStack {
                    if session.canRetryConnecting, session.barItem == nil {
                        Button(String(localized: "mobile.chief.outbox.retry", defaultValue: "Retry", bundle: .module)) { session.retryConnecting() }
                            .disabled(session.isReconnecting)
                    }
                    Spacer()
                    Button(String(localized: "mobile.chief.outbox.deleteAll", defaultValue: "Delete All", bundle: .module), role: .destructive) { session.discardOutbox() }
                }
                .font(theme.type.meta)
                .frame(minHeight: theme.metrics.glassButton)
            }
            .padding(.horizontal, theme.metrics.sideMargin)
            .background(Color.cmuxMobileBackground)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in resized() }
            .onDisappear { resized() }
            .accessibilityIdentifier("chief.outbox")
        }
    }
}
#endif
