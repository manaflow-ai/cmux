public import SwiftUI
public import CoreGraphics

/// The terminal-content / left-sidebar / right-sidebar layout, extracted from
/// `ContentView.contentAndSidebarLayout`.
///
/// Owns the package-knowable layout scaffolding: the overlay-vs-HStack choice
/// (blend mode + match-terminal-background), the left-sidebar leading inset
/// driven by `WindowChromeController.sidebarWidth`, and the resizer-overlay
/// overlays gated on sidebar visibility. The actual subviews (terminal content
/// with drop overlay, the left/right sidebar panels with backdrops, and the
/// resizer overlays) are app-target / `CmuxAppKitSupportUI` views supplied as
/// slots, since `CmuxWindowing` cannot import them without a dependency cycle.
public struct ContentAndSidebarLayoutView<
    TerminalDropContent: View,
    RightSidebarPanel: View,
    LeftSidebarPanel: View,
    SidebarResizer: View,
    RightSidebarResizer: View
>: View {
    @State private var controller: WindowChromeController
    private let useWithinWindow: Bool
    private let isSidebarVisible: Bool
    private let isRightSidebarVisible: Bool
    private let terminalDropContent: () -> TerminalDropContent
    private let rightSidebarPanel: () -> RightSidebarPanel
    private let leftSidebarPanel: () -> LeftSidebarPanel
    private let sidebarResizer: () -> SidebarResizer
    private let rightSidebarResizer: () -> RightSidebarResizer

    /// Creates the content + sidebar layout.
    /// - Parameters:
    ///   - controller: window-chrome state owner (read for `sidebarWidth`).
    ///   - useWithinWindow: whether to use the overlay (within-window blur) layout
    ///     instead of the standard HStack layout.
    ///   - isSidebarVisible: whether the left sidebar is shown.
    ///   - isRightSidebarVisible: whether the right sidebar is shown.
    ///   - terminalDropContent: terminal content with the sidebar drop overlay.
    ///   - rightSidebarPanel: the right sidebar panel with its backdrop.
    ///   - leftSidebarPanel: the left sidebar panel with its backdrop.
    ///   - sidebarResizer/rightSidebarResizer: the two resizer overlays.
    public init(
        controller: WindowChromeController,
        useWithinWindow: Bool,
        isSidebarVisible: Bool,
        isRightSidebarVisible: Bool,
        @ViewBuilder terminalDropContent: @escaping () -> TerminalDropContent,
        @ViewBuilder rightSidebarPanel: @escaping () -> RightSidebarPanel,
        @ViewBuilder leftSidebarPanel: @escaping () -> LeftSidebarPanel,
        @ViewBuilder sidebarResizer: @escaping () -> SidebarResizer,
        @ViewBuilder rightSidebarResizer: @escaping () -> RightSidebarResizer
    ) {
        _controller = State(initialValue: controller)
        self.useWithinWindow = useWithinWindow
        self.isSidebarVisible = isSidebarVisible
        self.isRightSidebarVisible = isRightSidebarVisible
        self.terminalDropContent = terminalDropContent
        self.rightSidebarPanel = rightSidebarPanel
        self.leftSidebarPanel = leftSidebarPanel
        self.sidebarResizer = sidebarResizer
        self.rightSidebarResizer = rightSidebarResizer
    }

    @ViewBuilder
    private var layout: some View {
        if useWithinWindow {
            // Overlay mode keeps the left sidebar on top, but the right sidebar
            // stays in an HStack so terminal rows are clipped before the sidebar
            // backdrop samples the window.
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    terminalDropContent()
                        .padding(.leading, isSidebarVisible ? controller.sidebarWidth : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    rightSidebarPanel()
                }
                if isSidebarVisible {
                    leftSidebarPanel()
                }
            }
        } else {
            // Standard HStack mode for behindWindow blur.
            HStack(spacing: 0) {
                if isSidebarVisible {
                    leftSidebarPanel()
                }
                HStack(spacing: 0) {
                    terminalDropContent()
                    rightSidebarPanel()
                }
            }
        }
    }

    public var body: some View {
        layout
            .overlay(alignment: .leading) {
                if isSidebarVisible {
                    sidebarResizer()
                        .zIndex(1000)
                }
            }
            .overlay(alignment: .leading) {
                if isRightSidebarVisible {
                    rightSidebarResizer()
                        .zIndex(1000)
                }
            }
    }
}
