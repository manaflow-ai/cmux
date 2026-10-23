import AppKit

/// Key-window changes refresh that window's hover (`PointerHover`).
///
/// Block observers on `queue: .main`, not selectors: AppKit may post these
/// off the main thread, and a selector into this main-actor class trapped
/// there (#18771). `queue: .main` runs the block inline when the post is on
/// main, so key changes and closes keep their synchronous order.
@MainActor
final class KeyWindowObserver {
    private var tokens: [any NSObjectProtocol] = []
    /// Where the key and close notices come from: AppKit's center in the app, a private one in
    /// a test (a post there reaches no other suite and no AppKit observer).
    private let notices: NotificationCenter

    /// - Parameter notices: the center AppKit posts the window notices to (`.default` in the
    ///   app); a test passes its own and posts there.
    init(notices: NotificationCenter) {
        self.notices = notices
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(notices.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { PointerHover.refresh(in: window) } // main-proof: observer on queue: .main
            })
        }
        #if DEBUG
        // A closed window's synthesized pointer must not pass to a new window
        // that reuses its address.
        tokens.append(notices.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            let key = ObjectIdentifier(window)
            MainActor.assumeIsolated { PointerHover.debugPointers[key] = nil } // main-proof: observer on queue: .main
        })
        #endif
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            for token in tokens { notices.removeObserver(token) }
        }
    }
}
