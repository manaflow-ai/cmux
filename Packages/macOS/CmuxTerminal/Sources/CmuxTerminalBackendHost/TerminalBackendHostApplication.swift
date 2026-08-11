public import SwiftUI

/// The standalone application that hosts backend-owned terminal presentations.
public struct TerminalBackendHostApplication: App {
    @State private var model: BackendOnlyHostModel

    /// Creates the backend-only host application.
    public init() {
        _model = State(initialValue: BackendOnlyHostModel())
    }

    /// The backend-only host scene.
    public var body: some Scene {
        Window(
            backendOnlyLocalizedString(
                "backendOnly.window.title",
                defaultValue: "cmux Backend"
            ),
            id: "backend-only-main"
        ) {
            BackendOnlyHostRootView(model: model)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { model.start() }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1120, height: 720)
    }
}
