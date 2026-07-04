import Foundation

@MainActor
enum InboxRuntimeRegistry {
    private(set) static weak var current: InboxRuntime?

    static func install(_ runtime: InboxRuntime) {
        current = runtime
    }
}

extension AppDelegate {
    /// Wires the Inbox runtime into the delegate during `AppDelegate.configure`.
    /// Runs in the App initializer, before any main window (and its
    /// `NSHostingView`-rooted ContentView) is created, so `.environment(inboxRuntime)`
    /// on that root never sees nil and socket handlers can resolve the registry.
    func installInboxRuntime(_ runtime: InboxRuntime) {
        inboxRuntime = runtime
        InboxRuntimeRegistry.install(runtime)
        runtime.start()
    }
}
