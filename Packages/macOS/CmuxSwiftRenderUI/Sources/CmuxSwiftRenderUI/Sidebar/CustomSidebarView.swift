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
    ///   - interpreter: The interpreter the `.swift` source renders through.
    ///     Defaults to the in-process implementation; the app injects an
    ///     out-of-process, crash-isolating ``SidebarInterpreting`` so an
    ///     interpreter fault from an untrusted sidebar can't crash the host.
    public init(
        fileURL: URL,
        dataContext: [String: SwiftValue],
        dispatch: SidebarActionDispatch,
        contentInsets: CustomSidebarContentInsets = .zero,
        interpreter: any SidebarInterpreting = InProcessSidebarInterpreter()
    ) {
        _model = State(initialValue: CustomSidebarModel(fileURL: fileURL, interpreter: interpreter))
        self.dataContext = dataContext
        self.dispatch = dispatch
        self.contentInsets = contentInsets
    }

    public var body: some View {
        // The pure presentation is shared with the out-of-process render
        // worker (see CustomSidebarContentView), so the two paths can't drift.
        CustomSidebarContentView(
            state: model.state,
            swiftRender: model.swiftRender,
            hasRenderedSwift: model.hasRenderedSwift,
            dispatch: dispatch,
            contentInsets: contentInsets
        )
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // Re-interpret whenever the live data changes or the source
        // reloads. `.task(id:)` cancels the prior render, so a superseded
        // tick's result is discarded rather than published stale.
        .task(id: SwiftRenderTrigger(sourceRevision: model.sourceRevision, dataContext: dataContext)) {
            await model.renderSwift(dataContext: dataContext)
        }
    }
}

/// The value the sidebar's interpret `.task(id:)` keys on. It changes when the
/// loaded source reloads (`sourceRevision`) or the live `dataContext` changes,
/// re-running the render. `Equatable` is enough for `.task(id:)`.
private struct SwiftRenderTrigger: Equatable {
    let sourceRevision: Int
    let dataContext: [String: SwiftValue]
}
