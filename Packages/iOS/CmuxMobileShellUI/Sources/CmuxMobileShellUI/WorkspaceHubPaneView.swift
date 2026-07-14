import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if canImport(UIKit)
import CoreGraphics
#endif

/// One snapshot-isolated pane card in the live workspace hub.
struct WorkspaceHubPaneView: View {
    let pane: WorkspaceHubPaneSnapshot
    let connectionStatus: MobileMacConnectionStatus
    let supportsBrowserPreview: Bool
    let previewUpdates: (String) -> AsyncStream<PreviewGridSnapshot>
    let browserPreviewUpdates: (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>
    let transitionNamespace: Namespace.ID
    let select: () -> Void
    private let imageDecoder = BrowserPreviewImageDecoder()
    @State private var isVisible = false
    @State private var snapshot: PreviewGridSnapshot
    @State private var browserImage: CGImage?

    init(
        pane: WorkspaceHubPaneSnapshot,
        connectionStatus: MobileMacConnectionStatus,
        supportsBrowserPreview: Bool,
        previewUpdates: @escaping (String) -> AsyncStream<PreviewGridSnapshot>,
        browserPreviewUpdates: @escaping (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>,
        transitionNamespace: Namespace.ID,
        select: @escaping () -> Void
    ) {
        self.pane = pane
        self.connectionStatus = connectionStatus
        self.supportsBrowserPreview = supportsBrowserPreview
        self.previewUpdates = previewUpdates
        self.browserPreviewUpdates = browserPreviewUpdates
        self.transitionNamespace = transitionNamespace
        self.select = select
        _snapshot = State(initialValue: .awaitingBaseline(surfaceID: pane.activeSurfaceID ?? ""))
    }

    var body: some View {
        Button(action: select) {
            paneCard
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(resolvedTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("MobileWorkspaceHubPane-\(pane.id)")
        .matchedTransitionSource(id: pane.id, in: transitionNamespace)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
        }
        .task(id: previewTaskID) {
            await consumePreviewIfNeeded()
        }
    }

    private var paneCard: some View {
        ZStack(alignment: .bottomLeading) {
            paneThumbnail
                .opacity(connectionStatus == .connected ? 1 : 0.3)

            LinearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 54)
            .accessibilityHidden(true)

            paneCaption
            .padding(8)

            if connectionStatus != .connected {
                Text(connectionStatus.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.78), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
        }
        .background(TerminalPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focusBorderColor, lineWidth: pane.focusState == .focused ? 3 : 1)
        }
        .overlay {
            if pane.focusState == .focused {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 3)
                    .accessibilityElement()
                    .accessibilityLabel(L10n.string("mobile.workspaceHub.focused", defaultValue: "Focused"))
                    .accessibilityIdentifier("MobileWorkspaceHubFocus-\(pane.id)")
            }
        }
    }

    @ViewBuilder
    private var paneThumbnail: some View {
        if pane.activeKind == .browser {
            #if canImport(UIKit)
            if let browserImage {
                Image(decorative: browserImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                browserFallback
            }
            #else
            browserFallback
            #endif
        } else {
            TerminalGridThumbnailView(snapshot: snapshot)
        }
    }

    private var browserFallback: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            Image(systemName: "safari.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }

    private var paneCaption: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                captionTitle
                Spacer(minLength: 0)
                captionMetadata
            }
            captionTitle
        }
    }

    private var captionTitle: some View {
        Text(resolvedTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var captionMetadata: some View {
        HStack(spacing: 6) {
            if pane.tabCount > 1 {
                Text("\(pane.tabCount)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: Capsule())
            }
            if let statusSymbolName {
                Image(systemName: statusSymbolName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusTint)
                    .accessibilityHidden(true)
            }
            if pane.chatAgentStatus != nil {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(pane.chatAgentStatus == .needsInput ? .orange : .green)
                    .accessibilityHidden(true)
            }
        }
    }

    private var resolvedTitle: String {
        pane.activeTitle.isEmpty
            ? L10n.string("mobile.workspaceHub.untitled", defaultValue: "Untitled")
            : pane.activeTitle
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if pane.tabCount > 1 {
            let format = L10n.string("mobile.workspaceHub.tabCountFormat", defaultValue: "%d tabs")
            values.append(String(format: format, pane.tabCount))
        }
        if pane.focusState == .focused {
            values.append(L10n.string("mobile.workspaceHub.focused", defaultValue: "Focused"))
        }
        if connectionStatus != .connected {
            values.append(connectionStatus.label)
        }
        if let agentStatusLabel {
            values.append(agentStatusLabel)
        } else if pane.hasUnread {
            values.append(L10n.string("mobile.workspaceHub.attention", defaultValue: "Needs attention"))
        }
        return values.joined(separator: ", ")
    }

    private var statusSymbolName: String? {
        if pane.agentStatus == .needsInput { return "questionmark.bubble.fill" }
        if pane.hasUnread { return "bell.badge.fill" }
        return switch pane.agentStatus {
        case .running: "bolt.fill"
        case .idle: "pause.circle.fill"
        case .unknown: "circle.dashed"
        case .needsInput: "questionmark.bubble.fill"
        case nil: nil
        }
    }

    private var statusTint: Color {
        if pane.agentStatus == .needsInput || pane.hasUnread { return .orange }
        if pane.agentStatus == .running { return .green }
        return .secondary
    }

    private var agentStatusLabel: String? {
        switch pane.agentStatus {
        case .running:
            L10n.string("mobile.workspaceHub.agent.running", defaultValue: "Agent running")
        case .idle:
            L10n.string("mobile.workspaceHub.agent.idle", defaultValue: "Agent idle")
        case .needsInput:
            L10n.string("mobile.workspaceHub.agent.needsInput", defaultValue: "Agent needs input")
        case .unknown:
            L10n.string("mobile.workspaceHub.agent.unknown", defaultValue: "Agent status unknown")
        case nil:
            nil
        }
    }

    private var focusBorderColor: Color {
        pane.focusState == .focused ? .accentColor : .white.opacity(0.16)
    }

    private var previewTaskID: String {
        "\(pane.activeSurfaceID ?? "none")|\(isVisible)|\(connectionStatus == .connected)"
    }

    @MainActor
    private func consumePreviewIfNeeded() async {
        if pane.activeKind == .browser {
            await consumeBrowserPreviewIfNeeded()
            return
        }
        let visibleIDs = isVisible ? Set([pane.id]) : []
        let demand = WorkspaceHubPreviewDemand(panes: [pane], visiblePaneIDs: visibleIDs)
        guard connectionStatus == .connected,
              let surfaceID = pane.activeSurfaceID,
              demand.surfaceIDs.contains(surfaceID) else { return }
        snapshot = .awaitingBaseline(surfaceID: surfaceID)
        for await update in previewUpdates(surfaceID) {
            guard !Task.isCancelled else { return }
            snapshot = update
        }
    }

    @MainActor
    private func consumeBrowserPreviewIfNeeded() async {
        guard supportsBrowserPreview, isVisible, connectionStatus == .connected,
              let surfaceID = pane.activeSurfaceID else { return }
        for await update in browserPreviewUpdates(surfaceID, .preview) {
            guard !Task.isCancelled else { return }
            guard let decoded = await imageDecoder.decode(
                update.imageData,
                maxPixelDimension: 900
            ), !Task.isCancelled else { continue }
            browserImage = decoded
        }
    }
}
