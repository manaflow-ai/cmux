public import SwiftUI
public import CoreGraphics

/// Full-width titlebar band that hosts the custom titlebar and the
/// always-visible fullscreen controls overlay.
///
/// Extracted from `ContentView.workspaceTitlebarBand`. Owns the band's
/// package-knowable layout (full width, chrome height, the right-sidebar
/// trailing inset that cedes the right-sidebar mode bar, and the
/// fullscreen-controls placement). The titlebar content and the fullscreen
/// controls are supplied as view slots by the app host (they reach app-target /
/// `CmuxAppKitSupportUI` chrome that `CmuxWindowing` cannot import without a
/// dependency cycle).
public struct WorkspaceTitlebarBandView<Titlebar: View, FullscreenControls: View>: View {
    @State private var controller: WindowChromeController
    private let isSidebarVisible: Bool
    private let rightSidebarWidth: CGFloat
    private let titlebar: () -> Titlebar
    private let fullscreenControls: () -> FullscreenControls

    /// Creates the titlebar band.
    /// - Parameters:
    ///   - controller: the window-chrome state owner (read for `isFullScreen`).
    ///   - isSidebarVisible: whether the left sidebar is shown.
    ///   - rightSidebarWidth: width of the right sidebar (0 when hidden); the band
    ///     cedes this trailing region so the right-sidebar mode bar stays hittable.
    ///   - titlebar: the custom titlebar content slot.
    ///   - fullscreenControls: the fullscreen titlebar controls slot.
    public init(
        controller: WindowChromeController,
        isSidebarVisible: Bool,
        rightSidebarWidth: CGFloat,
        @ViewBuilder titlebar: @escaping () -> Titlebar,
        @ViewBuilder fullscreenControls: @escaping () -> FullscreenControls
    ) {
        _controller = State(initialValue: controller)
        self.isSidebarVisible = isSidebarVisible
        self.rightSidebarWidth = rightSidebarWidth
        self.titlebar = titlebar
        self.fullscreenControls = fullscreenControls
    }

    public var body: some View {
        Color.clear
            .frame(height: WindowChromeLayoutMetrics.appTitlebarHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                titlebar()
                    // The band spans the full window width at zIndex(100). Its
                    // drag/double-click surface must not cover the right sidebar,
                    // whose mode bar lives inside the titlebar-height strip,
                    // otherwise the band wins the hit-test and swallows clicks on
                    // those buttons (#5099). Confine the interactive surface to
                    // the area left of the right sidebar. `rightSidebarWidth`
                    // collapses to 0 when the sidebar is hidden; the panel snaps
                    // without animation, so match that here.
                    .padding(.trailing, rightSidebarWidth)
                    .animation(nil, value: rightSidebarWidth)
            }
            .overlay(alignment: .topLeading) {
                if let placement = WindowChromeController.fullscreenControlsPlacement(
                    isFullScreen: controller.isFullScreen,
                    isSidebarVisible: isSidebarVisible
                ) {
                    fullscreenControls()
                        // Same vertical frame as the title row so the controls'
                        // center matches the folder icon / title.
                        .frame(
                            height: max(1, WindowChromeLayoutMetrics.appTitlebarHeight - 2),
                            alignment: .center
                        )
                        .padding(.top, placement.topPadding)
                        .padding(.leading, placement.leadingPadding)
                }
            }
    }
}
