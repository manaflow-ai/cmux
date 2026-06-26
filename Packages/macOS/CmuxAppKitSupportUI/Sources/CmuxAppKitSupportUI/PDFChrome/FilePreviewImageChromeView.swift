import CmuxFoundation
public import SwiftUI

/// The zoom-and-rotate chrome bar overlaid on the file-preview image viewer.
///
/// Two liquid-glass capsule groups of ``FilePreviewChromeIconButton``s: the
/// first holds zoom-out, actual-size, and zoom-in; the second holds zoom-to-fit,
/// rotate-left, and rotate-right, separated by hairline dividers. All actions
/// are injected closures and all labels arrive pre-localized via
/// ``FilePreviewImageChromeStrings``.
public struct FilePreviewImageChromeView: View {
    let strings: FilePreviewImageChromeStrings
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let zoomToFit: () -> Void
    let actualSize: () -> Void
    let rotateLeft: () -> Void
    let rotateRight: () -> Void

    /// Creates the image chrome bar.
    /// - Parameters:
    ///   - strings: The pre-localized button labels, resolved app-side.
    ///   - zoomOut: Zooms the image out.
    ///   - zoomIn: Zooms the image in.
    ///   - zoomToFit: Fits the image to the viewport.
    ///   - actualSize: Resets the image to its actual pixel size.
    ///   - rotateLeft: Rotates the image counter-clockwise.
    ///   - rotateRight: Rotates the image clockwise.
    public init(
        strings: FilePreviewImageChromeStrings,
        zoomOut: @escaping () -> Void,
        zoomIn: @escaping () -> Void,
        zoomToFit: @escaping () -> Void,
        actualSize: @escaping () -> Void,
        rotateLeft: @escaping () -> Void,
        rotateRight: @escaping () -> Void
    ) {
        self.strings = strings
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
                    label: strings.zoomOut,
                    action: zoomOut
                )
                chromeDivider
                FilePreviewChromeIconButton(
                    systemName: "1.magnifyingglass",
                    label: strings.actualSize,
                    action: actualSize
                )
                chromeDivider
                FilePreviewChromeIconButton(
                    systemName: "plus.magnifyingglass",
                    label: strings.zoomIn,
                    action: zoomIn
                )
            }
            .frame(height: 40)
            .modifier(FilePreviewPDFChromeStyleModifier(variant: .liquidGlass))

            HStack(spacing: 0) {
                FilePreviewChromeIconButton(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    label: strings.zoomToFit,
                    action: zoomToFit
                )
                chromeDivider
                FilePreviewChromeIconButton(
                    systemName: "rotate.left",
                    label: strings.rotateLeft,
                    action: rotateLeft
                )
                chromeDivider
                FilePreviewChromeIconButton(
                    systemName: "rotate.right",
                    label: strings.rotateRight,
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
