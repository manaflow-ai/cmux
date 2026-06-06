import CmuxSwiftRender
import SwiftUI

/// Renders a custom sidebar (interpreted Swift or declarative JSON) in the
/// cmux sidebar area.
///
/// Mount with `.id(fileURL)` at the call site so selecting a different
/// custom-sidebar provider rebuilds the model against the new file. The host
/// supplies the live `dataContext` (workspace state the interpreter binds to)
/// and a ``SidebarActionDispatch`` that runs button actions.
///
/// ```swift
/// CustomSidebarView(fileURL: url, dataContext: context, dispatch: dispatch)
///     .id(url)
/// ```
public struct CustomSidebarView: View {
    @State private var model: CustomSidebarModel
    private let dataContext: [String: SwiftValue]
    private let dispatch: SidebarActionDispatch
    private let contentInsets: CustomSidebarContentInsets

    /// Creates a sidebar bound to a file, a live data context, and an action
    /// dispatch.
    ///
    /// - Parameters:
    ///   - fileURL: The `.swift` or `.json` sidebar file to render and watch.
    ///   - dataContext: Live, read-only values the interpreter binds to.
    ///   - dispatch: Runs button/tap actions against the host command surface.
    ///   - contentInsets: Top/bottom scroll insets so content rests below the
    ///     window titlebar accessory and fades into the host's top mask when
    ///     scrolled, instead of underlapping it. Defaults to
    ///     ``CustomSidebarContentInsets/zero``.
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero
    ) {
        _model = State(initialValue: CustomSidebarModel(fileURL: fileURL))
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
    }

    public var body: some View {
        content
            .environment(\.sidebarActionDispatch, dispatch)
            .environment(\.customSidebarContentInsets, contentInsets)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .missing:
            scrollWrap(
                Text(String(localized: "sidebar.custom.missing", defaultValue: "Sidebar file is empty or missing."))
                    .font(.caption)
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
            // The model caches the parsed AST and re-evaluates only against
            // `dataContext`, so live workspace state still drives re-renders
            // without re-parsing the source on every tick.
            if let node = model.renderNode(dataContext: dataContext) {
                // A split root owns its own per-column scrolling and fills the
                // sidebar height, so it is not wrapped in the outer ScrollView.
                if node.kind == .hsplit {
                    RenderNodeView(node: node)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    scrollWrap(RenderNodeView(node: node))
                }
            } else {
                scrollWrap(errorView(String(localized: "sidebar.custom.noView", defaultValue: "No supported SwiftUI view found.")))
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
                String(localized: "sidebar.custom.error", defaultValue: "Sidebar error"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.bold())
            .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
