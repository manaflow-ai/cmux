import AppKit
import SwiftUI

@main
struct NativeMuxDemoApp: App {
    @State private var model = FrontendModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(L10n.text("app.title", "cmux Native Frontend")) {
            RootView(model: model)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.connectIfConfigured()
                    Task { @MainActor in
                        await Task.yield()
                        DemoWindowPlacement.applyIfConfigured()
                    }
                }
                .onDisappear { model.shutdown() }
        }
        .defaultSize(width: 1280, height: 780)
    }
}
