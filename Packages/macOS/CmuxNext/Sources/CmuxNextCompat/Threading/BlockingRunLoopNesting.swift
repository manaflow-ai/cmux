#if DEBUG || CMUX_BLOCKING_CHECKS
internal import CoreFoundation

/// Sees nested runs of the main run loop while an ``allowBlocking(_:_:)`` scope is open: one
/// `CFRunLoopObserver` for entry and exit in the common modes, added when the outermost scope opens and
/// removed when it closes, so no observer runs outside a scope. The body runs inside a callout of the main run
/// loop, so every entry the observer sees is a nested run, and each exit after one is its return. Main thread
/// only.
///
/// A nested run in a mode outside the common modes (a private mode passed to `CFRunLoopRunInMode`) is not
/// seen. Synchronous callbacks from the body itself (a notification, KVO, a delegate call) share the
/// allowance, as in Chrome.
struct BlockingRunLoopNesting {
    /// Whether an allowance scope is open.
    private(set) var isOpen = false
    /// The allowances held back by nested runs, innermost last.
    var held: [BlockingAllowance?] = []
    private var observer: CFRunLoopObserver?

    /// A scope opens; `onNested(true)` runs when the run loop enters a nested run, `onNested(false)` when it
    /// returns from one. An inner scope (already open) adds nothing.
    mutating func enter(onNested: @escaping (Bool) -> Void) {
        guard !isOpen else { return }
        isOpen = true
        var nested = 0
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue, true, 0
        ) { _, activity in
            if activity == .entry {
                nested += 1
                onNested(true)
            } else if nested > 0 {
                nested -= 1
                onNested(false)
            }
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        self.observer = observer
    }

    /// A scope closes; the outermost one (`wasOpen` false: none was open before it) removes the observer.
    mutating func leave(wasOpen: Bool) {
        guard !wasOpen, isOpen else { return }
        if let observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopObserverInvalidate(observer)
        }
        observer = nil
        isOpen = false
        held.removeAll()
    }
}
#endif
