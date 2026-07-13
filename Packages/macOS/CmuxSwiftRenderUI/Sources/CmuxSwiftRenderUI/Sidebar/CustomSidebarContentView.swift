import CmuxFoundation
import CmuxSwiftRender
import SwiftUI

/// The pure presentation of a custom sidebar: file state in, pixels out.
///
/// Shared by both render paths so they cannot drift visually:
/// - ``CustomSidebarView`` (in-process fallback) feeds it from its observed
///   ``CustomSidebarModel``;
/// - the out-of-process render worker feeds it value snapshots it computed
///   itself and hosts it in an offscreen `NSHostingView` whose layer tree is
///   shared with the host window.
///
/// Holds no model reference and runs no tasks; everything arrives as values,
/// so it renders identically wherever it is mounted.
public struct CustomSidebarContentView: View {
    private let state: CustomSidebarModel.State
    private let swiftRender: RenderNode?
    private let hasRenderedSwift: Bool
    private let dispatch: SidebarActionDispatch
    private let contentInsets: CustomSidebarContentInsets

    /// Creates the sidebar presentation for a loaded file state.
    ///
    /// - Parameters:
    ///   - state: The loaded sidebar file state (see ``CustomSidebarModel/State``).
    ///   - swiftRender: The latest interpreted view tree for
    ///     ``CustomSidebarModel/State/swiftSource(_:)``, if any.
    ///   - hasRenderedSwift: Whether a first interpret has completed, so the
    ///     view can distinguish "still rendering" from "rendered, no view".
    ///   - dispatch: Runs button/tap actions against the host command surface.
    ///   - contentInsets: Top/bottom scroll insets reserved for the host's
    ///     titlebar accessory and footer chrome.
    public init(
        state: CustomSidebarModel.State,
        swiftRender: RenderNode?,
        hasRenderedSwift: Bool,
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets
    ) {
        self.state = state
        self.swiftRender = swiftRender
        self.hasRenderedSwift = hasRenderedSwift
        self.dispatch = dispatch
        self.contentInsets = contentInsets
    }

    public var body: some View {
        content
            .environment(\.sidebarActionDispatch, dispatch)
            .environment(\.customSidebarContentInsets, contentInsets)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .missing:
            scrollWrap(
                Text(String(localized: "sidebar.custom.missing", defaultValue: "Sidebar file is empty or missing.", bundle: .module))
                    .cmuxFont(.caption)
                    .foregroundStyle(.secondary)
            )
        case let .json(document):
            // Route JSON node actions through the same host dispatch the
            // interpreted path uses, so taps in a declarative sidebar run
            // instead of being silently dropped.
            scrollWrap(DSLSidebarRenderer(node: document.root) { action in
                dispatch.run(action.buttonAction)
            })
        case .swiftSource:
            // Keep showing the last interpreted result until the next one
            // lands so live re-renders don't flicker.
            if let node = swiftRender {
                // A split root owns its own per-column scrolling and fills the
                // sidebar height, so it is not wrapped in the outer ScrollView.
                if node.kind == .hsplit {
                    RenderNodeView(node: node)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    scrollWrap(RenderNodeView(node: node))
                }
            } else if hasRenderedSwift {
                scrollWrap(errorView(String(localized: "sidebar.custom.noView", defaultValue: "No supported SwiftUI view found.", bundle: .module)))
            } else {
                // First render in flight; an empty placeholder avoids flashing
                // the error state before the interpreter has answered.
                scrollWrap(Color.clear.frame(height: 1))
            }
        case let .failed(message):
            scrollWrap(errorView(message))
        }
    }

    /// Wraps non-split content in the scrolling container with host-owned
    /// outer insets (authors control inner spacing).
    ///
    /// The top/bottom `safeAreaInset`s reserve the titlebar-accessory and
    /// footer bands so content rests below the chrome and scrolls up into the
    /// host's edge-fade mask rather than clipping against it. This mirrors the
    /// default workspace sidebar's scroll treatment.
    private func scrollWrap(_ view: some View) -> some View {
        ScrollView {
            view
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: contentInsets.top).allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: contentInsets.bottom).allowsHitTesting(false)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                String(localized: "sidebar.custom.error", defaultValue: "Sidebar error", bundle: .module),
                systemImage: "exclamationmark.triangle.fill"
            )
            .cmuxFont(.caption, weight: .bold)
            .foregroundStyle(.orange)
            Text(message)
                .cmuxFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
