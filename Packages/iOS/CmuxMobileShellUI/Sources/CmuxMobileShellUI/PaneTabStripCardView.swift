import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One snapshot-isolated live card in the in-pane tab strip.
struct PaneTabStripCardView: View {
    let card: PaneTabStripCardSnapshot
    let isSelected: Bool
    let connectionStatus: MobileMacConnectionStatus
    let supportsBrowserPreview: Bool
    let previewUpdates: (String) -> AsyncStream<PreviewGridSnapshot>
    let browserPreviewUpdates: (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>
    let select: () -> Void
    @State private var isVisible = false
    @State private var snapshot: PreviewGridSnapshot
    @State private var browserFrame: MobileBrowserPreviewFrame?

    init(
        card: PaneTabStripCardSnapshot,
        isSelected: Bool,
        connectionStatus: MobileMacConnectionStatus,
        supportsBrowserPreview: Bool,
        previewUpdates: @escaping (String) -> AsyncStream<PreviewGridSnapshot>,
        browserPreviewUpdates: @escaping (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>,
        select: @escaping () -> Void
    ) {
        self.card = card
        self.isSelected = isSelected
        self.connectionStatus = connectionStatus
        self.supportsBrowserPreview = supportsBrowserPreview
        self.previewUpdates = previewUpdates
        self.browserPreviewUpdates = browserPreviewUpdates
        self.select = select
        _snapshot = State(initialValue: .awaitingBaseline(surfaceID: card.id))
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                thumbnail
                HStack(spacing: 5) {
                    Text(resolvedTitle)
                        .font(.caption2.weight(isSelected ? .bold : .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let statusSymbolName {
                        Image(systemName: statusSymbolName)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(statusTint)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(5)
            .frame(width: 128)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(resolvedTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("MobilePaneTabCard-\(card.id)")
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
        }
        .task(id: previewTaskID) {
            await consumePreviewIfNeeded()
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            switch card.kind {
            case .terminal:
                TerminalGridThumbnailView(snapshot: snapshot)
            case .mirroredBrowser:
                mirroredBrowserThumbnail
            case .localBrowser:
                kindPlaceholder(systemImage: "iphone.gen3", badge: localBrowserBadge)
            case .agentChat:
                kindPlaceholder(systemImage: "bubble.left.and.bubble.right.fill", badge: agentStateLabel)
            }
        }
            .frame(height: 56)
            .background(TerminalPalette.background)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(connectionStatus == .connected ? 1 : 0.35)
    }

    @ViewBuilder
    private var mirroredBrowserThumbnail: some View {
        #if canImport(UIKit)
        if let browserFrame, let image = UIImage(data: browserFrame.imageData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "safari.fill")
                        .font(.caption2)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(4)
                }
        } else {
            kindPlaceholder(systemImage: "safari.fill", badge: mirroredBrowserBadge)
        }
        #else
        kindPlaceholder(systemImage: "safari.fill", badge: mirroredBrowserBadge)
        #endif
    }

    private func kindPlaceholder(systemImage: String, badge: String) -> some View {
        ZStack {
            Color(uiColor: .tertiarySystemBackground)
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(badge)
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(4)
        }
    }

    private var localBrowserBadge: String {
        L10n.string("mobile.browser.local.badge", defaultValue: "On this iPhone")
    }

    private var mirroredBrowserBadge: String {
        L10n.string("mobile.browser.mirrored.badge", defaultValue: "Mac Browser")
    }

    private var agentStateLabel: String {
        switch card.agentStatus {
        case .needsInput:
            L10n.string("mobile.agentChat.state.waiting", defaultValue: "Waiting")
        case .idle, .unknown, nil:
            L10n.string("mobile.agentChat.state.idle", defaultValue: "Idle")
        case .running:
            L10n.string("mobile.agentChat.state.running", defaultValue: "Running")
        }
    }

    private var resolvedTitle: String {
        card.title.isEmpty
            ? L10n.string("mobile.workspaceHub.untitled", defaultValue: "Untitled")
            : card.title
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isSelected {
            values.append(L10n.string("mobile.paneTabStrip.selected", defaultValue: "Selected"))
        }
        if card.agentStatus == .needsInput || card.hasUnread {
            values.append(L10n.string("mobile.workspaceHub.attention", defaultValue: "Needs attention"))
        }
        return values.joined(separator: ", ")
    }

    private var statusSymbolName: String? {
        if card.agentStatus == .needsInput { return "questionmark.bubble.fill" }
        if card.hasUnread { return "bell.badge.fill" }
        return switch card.agentStatus {
        case .running: "bolt.fill"
        case .idle: "pause.circle.fill"
        case .unknown: "circle.dashed"
        case .needsInput: "questionmark.bubble.fill"
        case nil: nil
        }
    }

    private var statusTint: Color {
        if card.agentStatus == .needsInput || card.hasUnread { return .orange }
        if card.agentStatus == .running { return .green }
        return .secondary
    }

    private var previewTaskID: String {
        "\(card.id)|\(isVisible)|\(connectionStatus == .connected)"
    }

    @MainActor
    private func consumePreviewIfNeeded() async {
        guard card.kind == .terminal else {
            await consumeBrowserPreviewIfNeeded()
            return
        }
        let visibleIDs = isVisible ? Set([card.id]) : []
        let demand = PaneTabStripPreviewDemand(cards: [card], visibleCardIDs: visibleIDs)
        guard connectionStatus == .connected, demand.surfaceIDs.contains(card.sourceID) else { return }
        snapshot = .awaitingBaseline(surfaceID: card.sourceID)
        for await update in previewUpdates(card.sourceID) {
            guard !Task.isCancelled else { return }
            snapshot = update
        }
    }

    @MainActor
    private func consumeBrowserPreviewIfNeeded() async {
        guard card.kind == .mirroredBrowser, supportsBrowserPreview,
              isVisible, connectionStatus == .connected else { return }
        for await update in browserPreviewUpdates(card.sourceID, .preview) {
            guard !Task.isCancelled else { return }
            browserFrame = update
        }
    }
}
