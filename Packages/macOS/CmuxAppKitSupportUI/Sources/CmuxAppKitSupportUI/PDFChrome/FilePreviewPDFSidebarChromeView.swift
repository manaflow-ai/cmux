public import CmuxFoundation
public import SwiftUI

/// The sidebar-options menu bar in the file-preview PDF chrome.
///
/// Renders one of three layouts selected by the ``FilePreviewPDFChromeStyleVariant``:
/// a system `ControlGroup`, the liquid-glass capsule menu, or a plain styled
/// menu. The menu lets the viewer toggle the sidebar, pick the thumbnails or
/// table-of-contents sidebar (``FilePreviewPDFSidebarMode``), and pick the
/// continuous-scroll, single-page, or two-pages display layout
/// (``FilePreviewPDFDisplayMode``), reflecting the current selection with
/// checkmarks. All actions are injected closures and all titles arrive
/// pre-localized via ``FilePreviewPDFSidebarChromeStrings``.
public struct FilePreviewPDFSidebarChromeView: View {
    let isSidebarVisible: Bool
    let sidebarMode: FilePreviewPDFSidebarMode
    let displayMode: FilePreviewPDFDisplayMode
    let chromeStyleVariant: FilePreviewPDFChromeStyleVariant
    let strings: FilePreviewPDFSidebarChromeStrings
    let toggleSidebar: () -> Void
    let selectThumbnails: () -> Void
    let selectTableOfContents: () -> Void
    let selectContinuousScroll: () -> Void
    let selectSinglePage: () -> Void
    let selectTwoPages: () -> Void

    /// Creates the PDF sidebar chrome view.
    /// - Parameters:
    ///   - isSidebarVisible: Whether the auxiliary sidebar is currently shown.
    ///   - sidebarMode: The currently selected auxiliary sidebar.
    ///   - displayMode: The currently selected page-layout mode.
    ///   - chromeStyleVariant: The chrome styling variant to render.
    ///   - strings: The pre-localized titles, resolved app-side.
    ///   - toggleSidebar: Toggles sidebar visibility.
    ///   - selectThumbnails: Selects the thumbnails sidebar.
    ///   - selectTableOfContents: Selects the table-of-contents sidebar.
    ///   - selectContinuousScroll: Selects continuous-scroll layout.
    ///   - selectSinglePage: Selects single-page layout.
    ///   - selectTwoPages: Selects two-pages layout.
    public init(
        isSidebarVisible: Bool,
        sidebarMode: FilePreviewPDFSidebarMode,
        displayMode: FilePreviewPDFDisplayMode,
        chromeStyleVariant: FilePreviewPDFChromeStyleVariant,
        strings: FilePreviewPDFSidebarChromeStrings,
        toggleSidebar: @escaping () -> Void,
        selectThumbnails: @escaping () -> Void,
        selectTableOfContents: @escaping () -> Void,
        selectContinuousScroll: @escaping () -> Void,
        selectSinglePage: @escaping () -> Void,
        selectTwoPages: @escaping () -> Void
    ) {
        self.isSidebarVisible = isSidebarVisible
        self.sidebarMode = sidebarMode
        self.displayMode = displayMode
        self.chromeStyleVariant = chromeStyleVariant
        self.strings = strings
        self.toggleSidebar = toggleSidebar
        self.selectThumbnails = selectThumbnails
        self.selectTableOfContents = selectTableOfContents
        self.selectContinuousScroll = selectContinuousScroll
        self.selectSinglePage = selectSinglePage
        self.selectTwoPages = selectTwoPages
    }

    public var body: some View {
        if chromeStyleVariant == .systemControlGroup {
            ControlGroup {
                sidebarMenu
            } label: {
                Label(
                    strings.sidebarOptions,
                    systemImage: "sidebar.left"
                )
            }
            .controlSize(.regular)
            .accessibilityLabel(strings.sidebarOptions)
        } else if chromeStyleVariant == .liquidGlass {
            liquidGlassSidebarMenu
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))
                .accessibilityLabel(strings.sidebarOptions)
        } else {
            sidebarMenu
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))
                .accessibilityLabel(strings.sidebarOptions)
        }
    }

    private var sidebarMenu: some View {
        Menu {
            sidebarMenuItems
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .regular))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 58, height: 36)
            .contentShape(Capsule())
        }
    }

    private var liquidGlassSidebarMenu: some View {
        Menu {
            sidebarMenuItems
        } label: {
            FilePreviewChromeSidebarMenuLabel()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sidebarMenuItems: some View {
        Button(action: toggleSidebar) {
            Text(isSidebarVisible ? strings.hideSidebar : strings.showSidebar)
        }
        checkedMenuButton(
            title: strings.thumbnails,
            isSelected: sidebarMode == .thumbnails,
            action: selectThumbnails
        )
        checkedMenuButton(
            title: strings.tableOfContents,
            isSelected: sidebarMode == .tableOfContents,
            action: selectTableOfContents
        )
        Divider()
        checkedMenuButton(
            title: strings.continuousScroll,
            isSelected: displayMode == .continuousScroll,
            action: selectContinuousScroll
        )
        checkedMenuButton(
            title: strings.singlePage,
            isSelected: displayMode == .singlePage,
            action: selectSinglePage
        )
        checkedMenuButton(
            title: strings.twoPages,
            isSelected: displayMode == .twoPages,
            action: selectTwoPages
        )
    }

    private func checkedMenuButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if isSelected {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
        }
    }
}
