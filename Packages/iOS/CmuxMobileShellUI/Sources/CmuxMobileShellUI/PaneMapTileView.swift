import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// One proportional pane tile rendered from immutable layout and preview snapshots.
struct PaneMapTileView: View {
    let pane: MobilePaneNode
    let paneNumber: Int
    let paneCount: Int
    let isFocusedOnMac: Bool
    let terminalTheme: TerminalTheme
    let selectedSurfaceID: String?
    let phoneSelectedSurfaceID: String?
    let previewGrid: MobileTerminalRenderGridFrame?
    let isLoadingPreview: Bool
    let agentStateKind: ChatAgentStateKind?
    let selectPreviewSurface: (String) -> Void
    let jumpToTerminal: (String) -> Void

    private var selectedSurface: MobilePaneSurface? {
        guard let selectedSurfaceID else { return pane.surfaces.first }
        return pane.surfaces.first { $0.id == selectedSurfaceID }
    }

    private var isPhoneSelected: Bool {
        selectedSurface?.id == phoneSelectedSurfaceID
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(spacing: 0) {
            if let selectedSurface {
                tileContent(for: selectedSurface)
                    .opacity(selectedSurface.type.isTerminal ? 1 : 0.5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalTheme.terminalBackgroundColor, in: shape)
        .overlay {
            shape.stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .overlay {
            if isPhoneSelected {
                shape.stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(paneAccessibilityLabel)
        .accessibilityValue(
            isFocusedOnMac
                ? L10n.string("mobile.paneMap.focusedOnMac", defaultValue: "Focused on Mac")
                : ""
        )
        .accessibilityIdentifier("MobilePaneMapPane-\(pane.id)")
    }

    private func tileContent(for surface: MobilePaneSurface) -> some View {
        VStack(spacing: 0) {
            header(for: surface)

            if pane.surfaces.count > 1 {
                miniTabStrip
            }

            bodyContent(for: surface)
        }
    }

    private func header(for surface: MobilePaneSurface) -> some View {
        HStack(spacing: 4) {
            Text(paneNumber, format: .number)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(terminalTheme.terminalChromeForegroundColor.opacity(0.12))
                )
                .accessibilityLabel(paneAccessibilityLabel)
                .accessibilityIdentifier("MobilePaneMapPaneNumber-\(pane.id)")

            Image(systemName: systemImage(for: surface.type))
                .font(.caption2.weight(.medium))

            Text(surface.title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            if isFocusedOnMac {
                Label(
                    L10n.string("mobile.paneMap.focusedOnMac.short", defaultValue: "Mac"),
                    systemImage: "macwindow"
                )
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(terminalTheme.terminalChromeForegroundColor.opacity(0.12))
                )
                .accessibilityLabel(
                    L10n.string("mobile.paneMap.focusedOnMac", defaultValue: "Focused on Mac")
                )
            }

            if let agentStateKind {
                Circle()
                    .fill(statusColor(agentStateKind))
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(statusAccessibilityValue(agentStateKind))
            }
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .padding(6)
    }

    private var miniTabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 3) {
                ForEach(pane.surfaces, id: \.id) { surface in
                    let isSelectedTab = surface.id == selectedSurface?.id
                    Button {
                        selectPreviewSurface(surface.id)
                    } label: {
                        Text(surface.title)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(
                                isSelectedTab
                                    ? terminalTheme.terminalBackgroundColor
                                    : terminalTheme.terminalChromeForegroundColor.opacity(0.85)
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(minWidth: 44, maxWidth: 96)
                            .background(
                                Capsule().fill(
                                    isSelectedTab
                                        ? terminalTheme.terminalChromeForegroundColor.opacity(0.85)
                                        : terminalTheme.terminalChromeForegroundColor.opacity(0.10)
                                )
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(surfaceAccessibilityLabel(surface))
                    .accessibilityAddTraits(isSelectedTab ? .isSelected : [])
                    .accessibilityIdentifier("MobilePaneMapTab-\(surface.id)")
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func bodyContent(for surface: MobilePaneSurface) -> some View {
        if surface.type.isTerminal {
            Button {
                jumpToTerminal(surface.id)
            } label: {
                terminalPreview(surfaceID: surface.id)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                surfaceAccessibilityLabel(surface)
            )
            .accessibilityValue(statusAccessibilityValue(agentStateKind))
            .accessibilityIdentifier("MobilePaneMapTile-\(surface.id)")
        } else {
            VStack(spacing: 5) {
                Image(systemName: systemImage(for: surface.type))
                    .font(.system(size: 20, weight: .medium))
                Text(surface.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
        }
    }

    @ViewBuilder
    private func terminalPreview(surfaceID: String) -> some View {
        if let previewGrid, previewGrid.surfaceID == surfaceID {
            GeometryReader { geometry in
                let lines = previewGrid.paneMapPreviewRows()
                let fontSize = previewFontSize(
                    availableSize: geometry.size,
                    columns: previewGrid.columns,
                    lineCount: lines.count
                )

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                // Preview rows are terminal content, so they use the theme's
                // true foreground rather than the chrome-readable color.
                .foregroundStyle(terminalTheme.terminalForegroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .clipped()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        } else if isLoadingPreview {
            ProgressView()
                .controlSize(.mini)
                .tint(terminalTheme.terminalChromeForegroundColor.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }

    private func previewFontSize(
        availableSize: CGSize,
        columns: Int,
        lineCount: Int
    ) -> CGFloat {
        guard columns > 0, lineCount > 0 else { return 5 }
        let widthFit = availableSize.width / (CGFloat(columns) * 0.62)
        let heightFit = availableSize.height / (CGFloat(lineCount) * 1.12)
        return min(9, max(5, min(widthFit, heightFit)))
    }

    private func statusColor(_ kind: ChatAgentStateKind) -> Color {
        switch kind {
        case .working:
            return .green
        case .needsInput:
            return .orange
        }
    }

    private func systemImage(for type: MobilePaneSurfaceType) -> String {
        switch type {
        case .terminal:
            return "terminal"
        case .browser:
            return "globe"
        case .markdown:
            return "doc.text"
        case .agentSession:
            return "sparkles"
        case .workspaceTodo:
            return "checklist"
        case .filepreview:
            return "doc"
        case .project:
            return "folder"
        case .rightSidebarTool, .customSidebar, .extensionBrowser, .cloudVMLoading, .other:
            return "rectangle"
        }
    }

    private var paneAccessibilityLabel: String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.paneMap.panePosition",
                defaultValue: "Pane %d of %d"
            ),
            paneNumber,
            paneCount
        )
    }

    private func surfaceAccessibilityLabel(_ surface: MobilePaneSurface) -> String {
        if surface.type.isTerminal {
            return String.localizedStringWithFormat(
                L10n.string(
                    "mobile.surfaceDeck.chip.terminalInPane",
                    defaultValue: "%@, terminal, pane %d of %d"
                ),
                surface.title,
                paneNumber,
                paneCount
            )
        }
        return String.localizedStringWithFormat(
            L10n.string(
                "mobile.surfaceDeck.chip.unavailableInPane",
                defaultValue: "%@, unavailable on iPhone, pane %d of %d"
            ),
            surface.title,
            paneNumber,
            paneCount
        )
    }

    private func statusAccessibilityValue(_ kind: ChatAgentStateKind?) -> String {
        switch kind {
        case .working:
            return L10n.string(
                "mobile.agent.status.working",
                defaultValue: "Agent working"
            )
        case .needsInput:
            return L10n.string(
                "mobile.agent.status.needsInput",
                defaultValue: "Agent needs input"
            )
        case nil:
            return ""
        }
    }
}
