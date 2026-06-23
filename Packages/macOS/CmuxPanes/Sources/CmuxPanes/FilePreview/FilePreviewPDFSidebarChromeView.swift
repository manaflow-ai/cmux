public import SwiftUI

/// Floating PDF sidebar control: a menu that toggles the sidebar and switches
/// between thumbnails/table-of-contents and the continuous/single/two-page
/// display modes. Styled per the active `FilePreviewPDFChromeStyleVariant`.
public struct FilePreviewPDFSidebarChromeView: View {
    let isSidebarVisible: Bool
    let sidebarMode: FilePreviewPDFSidebarMode
    let displayMode: FilePreviewPDFDisplayMode
    let chromeStyleVariant: FilePreviewPDFChromeStyleVariant
    let toggleSidebar: () -> Void
    let selectThumbnails: () -> Void
    let selectTableOfContents: () -> Void
    let selectContinuousScroll: () -> Void
    let selectSinglePage: () -> Void
    let selectTwoPages: () -> Void

    /// Creates the sidebar chrome control wired to the preview's current state
    /// and action callbacks.
    public init(
        isSidebarVisible: Bool,
        sidebarMode: FilePreviewPDFSidebarMode,
        displayMode: FilePreviewPDFDisplayMode,
        chromeStyleVariant: FilePreviewPDFChromeStyleVariant,
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
                    String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"),
                    systemImage: "sidebar.left"
                )
            }
            .controlSize(.regular)
            .accessibilityLabel(String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"))
        } else if chromeStyleVariant == .liquidGlass {
            liquidGlassSidebarMenu
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))
                .accessibilityLabel(String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"))
        } else {
            sidebarMenu
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))
                .accessibilityLabel(String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"))
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
            Text(isSidebarVisible
                ? String(localized: "filePreview.pdf.hideSidebar", defaultValue: "Hide Sidebar")
                : String(localized: "filePreview.pdf.showSidebar", defaultValue: "Show Sidebar"))
        }
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.thumbnails", defaultValue: "Thumbnails"),
            isSelected: sidebarMode == .thumbnails,
            action: selectThumbnails
        )
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.tableOfContents", defaultValue: "Table of Contents"),
            isSelected: sidebarMode == .tableOfContents,
            action: selectTableOfContents
        )
        Divider()
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.continuousScroll", defaultValue: "Continuous Scroll"),
            isSelected: displayMode == .continuousScroll,
            action: selectContinuousScroll
        )
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.singlePage", defaultValue: "Single Page"),
            isSelected: displayMode == .singlePage,
            action: selectSinglePage
        )
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.twoPages", defaultValue: "Two Pages"),
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
