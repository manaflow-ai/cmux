public import SwiftUI

/// Floating image preview zoom/rotate control row, always rendered with the
/// liquid-glass chrome style.
public struct FilePreviewImageChromeView: View {
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let zoomToFit: () -> Void
    let actualSize: () -> Void
    let rotateLeft: () -> Void
    let rotateRight: () -> Void

    /// Creates the image chrome control wired to the preview's zoom/rotate
    /// actions.
    public init(
        zoomOut: @escaping () -> Void,
        zoomIn: @escaping () -> Void,
        zoomToFit: @escaping () -> Void,
        actualSize: @escaping () -> Void,
        rotateLeft: @escaping () -> Void,
        rotateRight: @escaping () -> Void
    ) {
        self.zoomOut = zoomOut
        self.zoomIn = zoomIn
        self.zoomToFit = zoomToFit
        self.actualSize = actualSize
        self.rotateLeft = rotateLeft
        self.rotateRight = rotateRight
    }

    public var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                FilePreviewChromeIconButton(
                    systemName: "minus.magnifyingglass",
                    label: String(localized: "filePreview.image.zoomOut", defaultValue: "Zoom Out"),
                    action: zoomOut
                )
                chromeDivider
                FilePreviewChromeIconButton(
                    systemName: "1.magnifyingglass",
                    label: String(localized: "filePreview.image.actualSize", defaultValue: "Actual Size"),
                    action: actualSize
                )
                chromeDivider
                FilePreviewChromeIconButton(
                    systemName: "plus.magnifyingglass",
                    label: String(localized: "filePreview.image.zoomIn", defaultValue: "Zoom In"),
                    action: zoomIn
                )
            }
            .frame(height: 40)
            .modifier(FilePreviewPDFChromeStyleModifier(variant: .liquidGlass))

            HStack(spacing: 0) {
                FilePreviewChromeIconButton(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    label: String(localized: "filePreview.image.zoomToFit", defaultValue: "Zoom to Fit"),
                    action: zoomToFit
                )
                chromeDivider
                FilePreviewChromeIconButton(
                    systemName: "rotate.left",
                    label: String(localized: "filePreview.image.rotateLeft", defaultValue: "Rotate Left"),
                    action: rotateLeft
                )
                chromeDivider
                FilePreviewChromeIconButton(
                    systemName: "rotate.right",
                    label: String(localized: "filePreview.image.rotateRight", defaultValue: "Rotate Right"),
                    action: rotateRight
                )
            }
            .frame(height: 40)
            .modifier(FilePreviewPDFChromeStyleModifier(variant: .liquidGlass))
        }
    }

    private var chromeDivider: some View {
        Divider()
            .frame(width: 1, height: 20)
            .overlay(Color.white.opacity(0.18))
    }
}
