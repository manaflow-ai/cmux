public import CmuxFoundation
public import SwiftUI

/// The zoom-and-rotate chrome bar overlaid on the file-preview PDF viewer.
///
/// Renders one of two layouts selected by ``FilePreviewPDFChromeStyleVariant``:
/// the system `ControlGroup` variant, or a pair of styled capsule groups (the
/// first holds zoom-out, actual-size, and zoom-in; the second holds zoom-to-fit,
/// rotate-left, and rotate-right) plus an optional standalone open-externally
/// menu. All actions are injected closures, all labels arrive pre-localized via
/// ``FilePreviewPDFZoomChromeStrings``, and the open-externally menu is injected
/// as an opaque ``AnyView`` so the app-side menu view stays app-side.
public struct FilePreviewPDFZoomChromeView: View {
    let chromeStyleVariant: FilePreviewPDFChromeStyleVariant
    let strings: FilePreviewPDFZoomChromeStrings
    let fileOpenMenu: AnyView?
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let zoomIn: () -> Void
    let zoomToFit: () -> Void
    let rotateLeft: () -> Void
    let rotateRight: () -> Void

    /// Creates the PDF zoom chrome bar.
    /// - Parameters:
    ///   - chromeStyleVariant: Selects the control-group vs styled-capsule layout.
    ///   - strings: The pre-localized button labels, resolved app-side.
    ///   - fileOpenMenu: The app-side open-externally menu, or `nil` when there is
    ///     no backing file URL.
    ///   - zoomOut: Zooms the document out.
    ///   - actualSize: Resets the document to its actual size.
    ///   - zoomIn: Zooms the document in.
    ///   - zoomToFit: Fits the document to the viewport.
    ///   - rotateLeft: Rotates the document counter-clockwise.
    ///   - rotateRight: Rotates the document clockwise.
    public init(
        chromeStyleVariant: FilePreviewPDFChromeStyleVariant,
        strings: FilePreviewPDFZoomChromeStrings,
        fileOpenMenu: AnyView?,
        zoomOut: @escaping () -> Void,
        actualSize: @escaping () -> Void,
        zoomIn: @escaping () -> Void,
        zoomToFit: @escaping () -> Void,
        rotateLeft: @escaping () -> Void,
        rotateRight: @escaping () -> Void
    ) {
        self.chromeStyleVariant = chromeStyleVariant
        self.strings = strings
        self.fileOpenMenu = fileOpenMenu
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
                if let fileOpenMenu {
                    fileOpenMenu
                }
            } label: {
                Label(
                    strings.zoomControls,
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

                if let fileOpenMenu {
                    HStack(spacing: 0) {
                        fileOpenMenu
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
            label: strings.zoomOut,
            action: zoomOut
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "1.magnifyingglass",
            label: strings.actualSize,
            action: actualSize
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "plus.magnifyingglass",
            label: strings.zoomIn,
            action: zoomIn
        )
    }

    @ViewBuilder
    private func secondaryButtons(includeDividers: Bool) -> some View {
        chromeButton(
            systemName: "arrow.up.left.and.arrow.down.right",
            label: strings.zoomToFit,
            action: zoomToFit
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "rotate.left",
            label: strings.rotateLeft,
            action: rotateLeft
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "rotate.right",
            label: strings.rotateRight,
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
