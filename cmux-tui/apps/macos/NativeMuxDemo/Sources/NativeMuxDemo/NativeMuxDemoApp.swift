import AppKit
import SwiftUI

@MainActor
final class NativeMuxDemoAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: FrontendModel
    private(set) var window: NSWindow?

    override init() {
        model = FrontendModel()
        super.init()
    }

    init(model: FrontendModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard window == nil else { return }

        let content = NSHostingController(
            rootView: RootView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("app.title", "cmux Native Frontend")
        window.contentViewController = content
        window.minSize = NSSize(width: 720, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        model.connectIfConfigured()

        Task { @MainActor in
            await Task.yield()
            guard self.window === window else { return }
            DemoWindowPlacement.applyIfConfigured()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.shutdown()
        window = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct NativeMuxDemoApp: App {
    @NSApplicationDelegateAdaptor(NativeMuxDemoAppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
