public import AppKit
public import SwiftUI

import CmuxAppKitSupportUI

/// The shared scroll-column chrome for both the workspace sidebar and the
/// extension sidebar: a `GeometryReader`-measured vertical `ScrollView` with the
/// overlay-scroller resolver background, symmetric top/bottom safe-area insets,
/// the soft edge fade mask, a draggable titlebar overlay, and (in minimal mode)
/// the hidden-titlebar control strip, finished with a cleared scroll background.
///
/// Holds no app-target state. The host injects the scrolling content (built from
/// the column's own `GeometryReader` proxy so the caller can derive its
/// viewport-stretched min-height), the AppKit scroll-view configuration closure,
/// the titlebar overlay, and the minimal-mode control strip through slots, so the
/// Bonsplit/CmuxWindowing-coupled drag handle and the
/// `TerminalNotificationStore`/`AppDelegate`-coupled controls never cross the
/// package boundary. The host keeps its own `ScrollViewReader`, drag-top drop
/// target, and reactive observers wrapped around (or attached to) this column.
public struct SidebarScrollColumn<Content: View, TitlebarOverlay: View, MinimalControls: View>: View {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let topScrimHeight: CGFloat
    let bottomScrimHeight: CGFloat
    let isMinimalMode: Bool
    let minimalControlsLeadingInset: CGFloat
    let minimalControlsTopPadding: CGFloat
    let configureScrollView: (NSScrollView?) -> Void
    let content: (GeometryProxy) -> Content
    let titlebarOverlay: () -> TitlebarOverlay
    let minimalControls: () -> MinimalControls

    /// Creates the shared sidebar scroll column.
    /// - Parameters:
    ///   - topInset: Top safe-area inset height reserved above the scroll content.
    ///   - bottomInset: Bottom safe-area inset height reserved below the content.
    ///   - topScrimHeight: Top edge-fade height; `0` keeps the top crisp.
    ///   - bottomScrimHeight: Bottom edge-fade height; `0` keeps the bottom crisp.
    ///   - isMinimalMode: Gates the minimal-mode control strip overlay.
    ///   - minimalControlsLeadingInset: Leading padding for the control strip.
    ///   - minimalControlsTopPadding: Top padding for the control strip.
    ///   - configureScrollView: Receives the resolved enclosing `NSScrollView`
    ///     (or `nil`) so the host can apply overlay-scroller configuration and
    ///     attach drag auto-scroll.
    ///   - content: The scrolling content, built from the column's own
    ///     `GeometryReader` proxy.
    ///   - titlebarOverlay: The top titlebar overlay (drag handle + double-click
    ///     monitor), injected so its windowing coupling stays app-side.
    ///   - minimalControls: The minimal-mode control strip, injected so its
    ///     notification-store/`AppDelegate` coupling stays app-side.
    public init(
        topInset: CGFloat,
        bottomInset: CGFloat,
        topScrimHeight: CGFloat,
        bottomScrimHeight: CGFloat,
        isMinimalMode: Bool,
        minimalControlsLeadingInset: CGFloat,
        minimalControlsTopPadding: CGFloat,
        configureScrollView: @escaping (NSScrollView?) -> Void,
        @ViewBuilder content: @escaping (GeometryProxy) -> Content,
        @ViewBuilder titlebarOverlay: @escaping () -> TitlebarOverlay,
        @ViewBuilder minimalControls: @escaping () -> MinimalControls
    ) {
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.topScrimHeight = topScrimHeight
        self.bottomScrimHeight = bottomScrimHeight
        self.isMinimalMode = isMinimalMode
        self.minimalControlsLeadingInset = minimalControlsLeadingInset
        self.minimalControlsTopPadding = minimalControlsTopPadding
        self.configureScrollView = configureScrollView
        self.content = content
        self.titlebarOverlay = titlebarOverlay
        self.minimalControls = minimalControls
    }

    public var body: some View {
        GeometryReader { geometryProxy in
            ScrollView(.vertical) {
                content(geometryProxy)
            }
            .background(
                SidebarScrollViewResolver { scrollView in
                    configureScrollView(scrollView)
                }
                .frame(width: 0, height: 0)
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: topInset)
                    .allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: bottomInset)
                    .allowsHitTesting(false)
            }
            .mask(
                SidebarWorkspaceScrollEdgeFadeMask(
                    topHeight: topScrimHeight,
                    bottomHeight: bottomScrimHeight
                )
            )
            .overlay(alignment: .top) {
                titlebarOverlay()
            }
            .overlay(alignment: .topLeading) {
                if isMinimalMode {
                    minimalControls()
                        .padding(.leading, minimalControlsLeadingInset)
                        .padding(.top, minimalControlsTopPadding)
                }
            }
            .background(Color.clear)
            .modifier(ClearScrollBackground())
        }
    }
}
