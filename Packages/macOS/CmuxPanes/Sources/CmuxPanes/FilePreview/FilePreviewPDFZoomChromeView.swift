public import Foundation
public import SwiftUI

/// Floating PDF zoom/rotate control row, plus an external-open control when a
/// `fileURL` is present. Styled per the active `FilePreviewPDFChromeStyleVariant`.
///
/// The external-open menu's localized titles arrive as `strings`, resolved
/// app-side (`FileExternalOpenStrings.live`) because `String(localized:)` must
/// bind to the app bundle's catalog, not this package's.
public struct FilePreviewPDFZoomChromeView: View {
    let chromeStyleVariant: FilePreviewPDFChromeStyleVariant
    let fileURL: URL?
    let strings: FileExternalOpenStrings
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let zoomIn: () -> Void
    let zoomToFit: () -> Void
    let rotateLeft: () -> Void
    let rotateRight: () -> Void

    /// Creates the zoom chrome control. `strings` carries the app-resolved
    /// external-open menu titles for the optional `fileURL` control.
    public init(
        chromeStyleVariant: FilePreviewPDFChromeStyleVariant,
        fileURL: URL?,
        strings: FileExternalOpenStrings,
        zoomOut: @escaping () -> Void,
        actualSize: @escaping () -> Void,
        zoomIn: @escaping () -> Void,
        zoomToFit: @escaping () -> Void,
        rotateLeft: @escaping () -> Void,
        rotateRight: @escaping () -> Void
    ) {
        self.chromeStyleVariant = chromeStyleVariant
        self.fileURL = fileURL
        self.strings = strings
        self.zoomOut = zoomOut
        self.actualSize = actualSize
        self.zoomIn = zoomIn
        self.zoomToFit = zoomToFit
        self.rotateLeft = rotateLeft
        self.rotateRight = rotateRight
    }

    public var body: some View {
        if chromeStyleVariant == .systemControlGroup {
            ControlGroup {
                zoomButtons(includeDividers: false)
                secondaryButtons(includeDividers: false)
                if let fileURL {
                    FileExternalOpenMenu(fileURL: fileURL, strings: strings, style: .chrome)
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
                        FileExternalOpenMenu(fileURL: fileURL, strings: strings, style: .chrome)
                    }
                    .frame(width: 40, height: 40)
                    .modifier(FilePreviewPDFStandaloneChromeStyleModifier(variant: chromeStyleVariant))
                }
            }
        }
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
                    .font(.system(size: 16, weight: .regular))
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
