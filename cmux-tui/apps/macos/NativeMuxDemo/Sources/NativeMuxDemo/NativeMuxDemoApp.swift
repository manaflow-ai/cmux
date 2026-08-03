import SwiftUI

@main
struct NativeMuxDemoApp: App {
    @State private var model = FrontendModel()

    var body: some Scene {
        WindowGroup(L10n.text("app.title", "cmux Native Frontend")) {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { model.connectIfConfigured() }
                .onDisappear { model.shutdown() }
        }
        .defaultSize(width: 1280, height: 780)
        .windowStyle(.hiddenTitleBar)
    }
}
