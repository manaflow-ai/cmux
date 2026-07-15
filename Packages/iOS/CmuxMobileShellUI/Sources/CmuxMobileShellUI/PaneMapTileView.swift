import CMUXMobileCore
import CmuxMobileShellModel
import SwiftUI

/// One proportional pane tile rendered from immutable layout and preview snapshots.
struct PaneMapTileView: View {
    let pane: MobilePaneNode
    let selectedSurfaceID: String?
    let phoneSelectedSurfaceID: String?
    let previewGrid: MobileTerminalRenderGridFrame?
    let isLoadingPreview: Bool
    let agentStateKind: ChatAgentStateKind?
    let selectPreviewSurface: (String) -> Void
    let jumpToTerminal: (String) -> Void

    private var selectedSurface: MobilePaneSurface? {
        guard let selectedSurfaceID else { return pane.surfaces.first }
        return pane.surfaces.first { $0.id == selectedSurfaceID } ?? pane.surfaces.first
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
        .background(TerminalPalette.background, in: shape)
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
            Image(systemName: systemImage(for: surface.type))
                .font(.system(size: 10, weight: .medium))

            Text(surface.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            if let agentStateKind {
                Circle()
                    .fill(statusColor(agentStateKind))
                    .frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(TerminalPalette.foreground)
        .padding(6)
    }

    private var miniTabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 3) {
                ForEach(pane.surfaces, id: \.id) { surface in
                    Button {
                        selectPreviewSurface(surface.id)
                    } label: {
                        Capsule()
                            .fill(
                                surface.id == selectedSurface?.id
                                    ? TerminalPalette.foreground.opacity(0.72)
                                    : .clear
                            )
                            .overlay {
                                Capsule().stroke(TerminalPalette.foreground.opacity(0.28), lineWidth: 1)
                            }
                            .frame(width: 16, height: 5)
                            .frame(width: 24, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(surface.title)
                    .accessibilityAddTraits(surface.id == selectedSurface?.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, 6)
        }
        .scrollIndicators(.hidden)
        .frame(height: 14)
    }

    @ViewBuilder
    private func bodyContent(for surface: MobilePaneSurface) -> some View {
        if surface.type.isTerminal {
            terminalPreview(surfaceID: surface.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    jumpToTerminal(surface.id)
                }
                .accessibilityAddTraits(.isButton)
        } else {
            VStack(spacing: 5) {
                Image(systemName: systemImage(for: surface.type))
                    .font(.system(size: 20, weight: .medium))
                Text(surface.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(TerminalPalette.foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
        }
    }

    @ViewBuilder
    private func terminalPreview(surfaceID: String) -> some View {
        if let previewGrid, previewGrid.surfaceID == surfaceID {
            GeometryReader { geometry in
                let lines = PaneMapPreviewRenderer.rows(in: previewGrid)
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
                .foregroundStyle(TerminalPalette.foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .clipped()
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        } else if isLoadingPreview {
            ProgressView()
                .controlSize(.mini)
                .tint(TerminalPalette.foreground.opacity(0.5))
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
        return min(7, max(5, min(widthFit, heightFit)))
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
}
