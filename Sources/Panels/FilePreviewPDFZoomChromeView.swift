import SwiftUI

struct FilePreviewPDFZoomChromeView: View {
    let chromeStyleVariant: FilePreviewPDFChromeStyleVariant
    let fileURL: URL?
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let zoomIn: () -> Void
    let zoomToFit: () -> Void
    let rotateLeft: () -> Void
    let rotateRight: () -> Void
    let refresh: () -> Void

    var body: some View {
        if chromeStyleVariant == .systemControlGroup {
            ControlGroup {
                zoomButtons(includeDividers: false)
                secondaryButtons(includeDividers: false)
                refreshButton
                if let fileURL {
                    FileExternalOpenMenu(fileURL: fileURL, style: .chrome)
                }
            } label: {
                Label(
                    String(localized: "filePreview.pdf.zoomControls", defaultValue: "Zoom Controls"),
                    systemImage: "magnifyingglass"
                )
            }
            .controlSize(.regular)
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    zoomButtons(includeDividers: true)
                }
                .frame(height: chromeStyleVariant == .liquidGlass ? 40 : 36)
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))

                HStack(spacing: 0) {
                    secondaryButtons(includeDividers: true)
                }
                .frame(height: chromeStyleVariant == .liquidGlass ? 40 : 36)
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))

                if let fileURL {
                    HStack(spacing: 0) {
                        refreshButton
                    }
                    .frame(width: 40, height: 40)
                    .modifier(FilePreviewPDFStandaloneChromeStyleModifier(variant: chromeStyleVariant))

                    HStack(spacing: 0) {
                        FileExternalOpenMenu(fileURL: fileURL, style: .chrome)
                    }
                    .frame(width: 40, height: 40)
                    .modifier(FilePreviewPDFStandaloneChromeStyleModifier(variant: chromeStyleVariant))
                }
            }
        }
    }

    private var refreshButton: some View {
        chromeButton(
            systemName: "arrow.clockwise",
            label: String(localized: "filePreview.refresh", defaultValue: "Refresh"),
            action: refresh
        )
    }

    @ViewBuilder
    private func zoomButtons(includeDividers: Bool) -> some View {
        chromeButton(
            systemName: "minus.magnifyingglass",
            label: String(localized: "filePreview.pdf.zoomOut", defaultValue: "Zoom Out"),
            action: zoomOut
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "1.magnifyingglass",
            label: String(localized: "filePreview.pdf.actualSize", defaultValue: "Actual Size"),
            action: actualSize
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "plus.magnifyingglass",
            label: String(localized: "filePreview.pdf.zoomIn", defaultValue: "Zoom In"),
            action: zoomIn
        )
    }

    @ViewBuilder
    private func secondaryButtons(includeDividers: Bool) -> some View {
        chromeButton(
            systemName: "arrow.up.left.and.arrow.down.right",
            label: String(localized: "filePreview.pdf.zoomToFit", defaultValue: "Zoom to Fit"),
            action: zoomToFit
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "rotate.left",
            label: String(localized: "filePreview.pdf.rotateLeft", defaultValue: "Rotate Left"),
            action: rotateLeft
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "rotate.right",
            label: String(localized: "filePreview.pdf.rotateRight", defaultValue: "Rotate Right"),
            action: rotateRight
        )
    }

    @ViewBuilder
    private func chromeButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        if chromeStyleVariant == .liquidGlass {
            FilePreviewChromeIconButton(systemName: systemName, label: label, action: action)
        } else {
            Button(action: action) {
                Image(systemName: systemName)
                    .cmuxFont(size: 16, weight: .regular)
                    .frame(width: 38, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(label)
            .help(label)
        }
    }

    private var chromeDivider: some View {
        Divider()
            .frame(width: 1, height: 20)
            .overlay(
                chromeStyleVariant == .liquidGlass
                    ? Color.white.opacity(0.18)
                    : Color.clear
            )
    }
}
