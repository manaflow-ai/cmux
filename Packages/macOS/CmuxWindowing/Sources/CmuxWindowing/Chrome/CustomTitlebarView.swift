public import SwiftUI
public import CoreGraphics

/// The cmux custom titlebar row, extracted from `ContentView.customTitlebar`.
///
/// Owns the package-knowable layout (band height, content height, leading
/// padding math, the `Text(titlebarText)` title) and observes
/// `WindowChromeController` for `titlebarText` / `isFullScreen` /
/// `sidebarWidth` / `titlebarLeadingInset`. The cross-slice chrome decorations
/// that live in the app target / `CmuxAppKitSupportUI` (`WindowDragHandleView`,
/// `TitlebarLeadingInsetReader`, `TitlebarDoubleClickMonitorView`,
/// `WindowChromeBorder`, the optional folder-drag icon) are supplied as view
/// slots so the band keeps its exact structure without a dependency cycle.
public struct CustomTitlebarView<DragHandle: View, InsetReader: View, FolderIcon: View, DoubleClickMonitor: View, BottomBorder: View>: View {
    @State private var controller: WindowChromeController
    private let titleTextColor: Color
    private let isSidebarVisible: Bool
    private let minimumSidebarWidth: CGFloat
    private let fullscreenControlsWidth: CGFloat
    private let dragHandle: () -> DragHandle
    private let insetReader: () -> InsetReader
    private let folderIcon: () -> FolderIcon
    private let doubleClickMonitor: () -> DoubleClickMonitor
    private let bottomBorder: () -> BottomBorder

    /// Creates the custom titlebar row.
    /// - Parameters:
    ///   - controller: the window-chrome state owner.
    ///   - titleTextColor: resolved title text color for the current appearance.
    ///   - isSidebarVisible: whether the left sidebar is shown.
    ///   - minimumSidebarWidth: the minimum allowed sidebar width.
    ///   - fullscreenControlsWidth: intrinsic width of the fullscreen controls,
    ///     reserved in the title row when fullscreen + sidebar hidden.
    ///   - dragHandle/insetReader/folderIcon/doubleClickMonitor/bottomBorder:
    ///     cross-slice chrome decoration slots supplied by the app host.
    public init(
        controller: WindowChromeController,
        titleTextColor: Color,
        isSidebarVisible: Bool,
        minimumSidebarWidth: CGFloat,
        fullscreenControlsWidth: CGFloat,
        @ViewBuilder dragHandle: @escaping () -> DragHandle,
        @ViewBuilder insetReader: @escaping () -> InsetReader,
        @ViewBuilder folderIcon: @escaping () -> FolderIcon,
        @ViewBuilder doubleClickMonitor: @escaping () -> DoubleClickMonitor,
        @ViewBuilder bottomBorder: @escaping () -> BottomBorder
    ) {
        _controller = State(initialValue: controller)
        self.titleTextColor = titleTextColor
        self.isSidebarVisible = isSidebarVisible
        self.minimumSidebarWidth = minimumSidebarWidth
        self.fullscreenControlsWidth = fullscreenControlsWidth
        self.dragHandle = dragHandle
        self.insetReader = insetReader
        self.folderIcon = folderIcon
        self.doubleClickMonitor = doubleClickMonitor
        self.bottomBorder = bottomBorder
    }

    public var body: some View {
        let titlebarContentHeight = max(1, WindowChromeLayoutMetrics.appTitlebarHeight - 2)
        let leadingPadding = WindowChromeController.customTitlebarLeadingPadding(
            isFullScreen: controller.isFullScreen,
            isSidebarVisible: isSidebarVisible,
            sidebarWidth: controller.sidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth,
            titlebarLeadingInset: controller.titlebarLeadingInset
        )
        return ZStack {
            // Enable window dragging from the titlebar strip without making the
            // entire content view draggable (which breaks drag gestures like tab
            // reordering).
            dragHandle()

            insetReader()
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                if controller.isFullScreen && !isSidebarVisible {
                    // Reserve the controls' width so the title flows to their
                    // right. The visible controls render once in the band overlay
                    // so their position never depends on sidebar visibility.
                    Color.clear
                        .frame(width: fullscreenControlsWidth, height: titlebarContentHeight)
                        .allowsHitTesting(false)
                }

                // Draggable folder icon + focused command name.
                folderIcon()

                Text(controller.titlebarText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(titleTextColor)
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer()
            }
            .frame(height: titlebarContentHeight)
            .padding(.top, 2)
            .padding(.leading, leadingPadding)
            .padding(.trailing, 8)
        }
        .frame(height: WindowChromeLayoutMetrics.appTitlebarHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(doubleClickMonitor())
        .overlay(alignment: .bottom) {
            bottomBorder()
                .padding(.leading, isSidebarVisible ? controller.sidebarWidth : 0)
        }
    }
}
