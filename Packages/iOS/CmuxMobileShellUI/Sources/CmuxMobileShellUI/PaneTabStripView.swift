import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Bottom live-thumbnail strip for the currently entered pane.
struct PaneTabStripView: View {
    let cards: [PaneTabStripCardSnapshot]
    let selectedCardID: String?
    let attentionShelfEnabled: Bool
    let connectionStatus: MobileMacConnectionStatus
    let supportsBrowserPreview: Bool
    let previewUpdates: (String) -> AsyncStream<PreviewGridSnapshot>
    let browserPreviewUpdates: (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>
    let select: (PaneTabStripCardSnapshot) -> Void
    let toggleAttentionShelf: () -> Void
    let createTerminal: () -> Void
    @State private var frozenCards: [PaneTabStripCardSnapshot]?
    @State private var isTouchingStrip = false

    var body: some View {
        HStack(spacing: 8) {
            attentionToggle
            cardsScroller
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .accessibilityIdentifier("MobilePaneTabStrip")
        .animation(.snappy(duration: 0.25), value: displayedCards.map(\.id))
        .simultaneousGesture(stripTouchTrackingGesture)
    }

    private var displayedCards: [PaneTabStripCardSnapshot] {
        frozenCards ?? cards
    }

    private var attentionToggle: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                toggleAttentionShelf()
            }
        } label: {
            Image(systemName: attentionShelfEnabled ? "bell.badge.fill" : "bell.badge")
                .font(.body.weight(.semibold))
                .foregroundStyle(attentionShelfEnabled ? Color.orange : .primary)
                .frame(width: 38, height: 72)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            L10n.string("mobile.paneTabStrip.attention", defaultValue: "Prioritize Attention")
        )
        .accessibilityValue(
            attentionShelfEnabled
                ? L10n.string("mobile.paneTabStrip.on", defaultValue: "On")
                : L10n.string("mobile.paneTabStrip.off", defaultValue: "Off")
        )
        .accessibilityIdentifier("MobilePaneAttentionShelfToggle")
    }

    private var cardsScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(displayedCards) { card in
                        PaneTabStripCardView(
                            card: card,
                            isSelected: card.id == selectedCardID,
                            connectionStatus: connectionStatus,
                            supportsBrowserPreview: supportsBrowserPreview,
                            previewUpdates: previewUpdates,
                            browserPreviewUpdates: browserPreviewUpdates,
                            select: { select(card) }
                        )
                        .id(card.id)
                    }
                    newTerminalButton
                        .id("pane-tab-strip-new-terminal")
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .onAppear { keepSelectionVisible(proxy: proxy, animated: false) }
            .onChange(of: selectedCardID) { _, _ in
                keepSelectionVisible(proxy: proxy, animated: true)
            }
            .onChange(of: displayedCards.map(\.id)) { _, _ in
                keepSelectionVisible(proxy: proxy, animated: true)
            }
        }
    }

    private var newTerminalButton: some View {
        Button(action: createTerminal) {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 72)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"))
        .accessibilityIdentifier("MobilePaneNewTerminalButton")
    }

    private func freezeCardOrder() {
        guard frozenCards == nil else { return }
        frozenCards = cards
    }

    private func releaseCardOrder() {
        withAnimation(.snappy(duration: 0.25)) {
            frozenCards = nil
        }
    }

    private var stripTouchTrackingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isTouchingStrip else { return }
                isTouchingStrip = true
                freezeCardOrder()
            }
            .onEnded { _ in
                isTouchingStrip = false
                releaseCardOrder()
            }
    }

    private func keepSelectionVisible(proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedCardID,
              displayedCards.contains(where: { $0.id == selectedCardID }) else { return }
        if animated {
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(selectedCardID, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedCardID, anchor: .center)
        }
    }
}
