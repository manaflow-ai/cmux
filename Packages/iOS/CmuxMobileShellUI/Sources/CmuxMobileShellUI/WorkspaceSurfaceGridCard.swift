import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct WorkspaceSurfaceGridItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case terminal(MobileTerminalPreview.ID)
        case browser
    }

    let id: String
    let workspaceID: MobileWorkspacePreview.ID
    let kind: Kind
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let isDimmed: Bool
    let canClose: Bool
}

struct WorkspaceSurfaceGridCard: View {
    let item: WorkspaceSurfaceGridItem
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    preview
                    label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.isDimmed ? 0.66 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("MobileSurfaceGridCard-\(item.id)")

            if item.canClose {
                closeButton
                    .padding(8)
            }
        }
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(previewFill)
            .overlay(previewOverlay)
            .overlay(alignment: .center) {
                previewContent
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(item.isSelected ? Color.accentColor.opacity(0.78) : .white.opacity(0.10), lineWidth: item.isSelected ? 2 : 1)
            )
            .aspectRatio(0.84, contentMode: .fit)
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.48), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(L10n.string("mobile.browser.close", defaultValue: "Close Browser"))
        .accessibilityIdentifier("MobileSurfaceGridCloseButton-\(item.id)")
    }

    private var previewFill: some ShapeStyle {
        switch item.kind {
        case .terminal:
            return AnyShapeStyle(TerminalPalette.background)
        case .browser:
            return AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        }
    }

    private var previewOverlay: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(item.kind == .browser ? 0.18 : 0.08),
                        .clear,
                        .black.opacity(item.kind == .browser ? 0.10 : 0.34),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    @ViewBuilder
    private var previewContent: some View {
        switch item.kind {
        case .terminal:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(.red.opacity(0.78)).frame(width: 7, height: 7)
                    Circle().fill(.yellow.opacity(0.82)).frame(width: 7, height: 7)
                    Circle().fill(.green.opacity(0.82)).frame(width: 7, height: 7)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    terminalLine(
                        L10n.string("mobile.surfaceGrid.terminalAttach", defaultValue: "$ cmux attach"),
                        opacity: 0.92
                    )
                    terminalLine(item.title, opacity: 0.74)
                    terminalLine(
                        item.detail.isEmpty
                            ? L10n.string("mobile.surfaceGrid.terminalReadyPrompt", defaultValue: "ready")
                            : item.detail,
                        opacity: 0.58
                    )
                    terminalLine("|", opacity: 0.90)
                }
                Spacer()
            }
            .padding(14)
        case .browser:
            VStack(spacing: 12) {
                HStack {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 16)
                    Image(systemName: "line.3.horizontal")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: item.systemImage)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 76, height: 76)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 6)
                Spacer()
            }
            .padding(14)
        }
    }

    private func terminalLine(_ text: String, opacity: Double) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(TerminalPalette.foreground.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(item.kind == .browser ? Color.accentColor : TerminalPalette.foreground)
                .frame(width: 22)
            Text(item.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(TerminalPalette.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
