import AppKit

/// Pops a native menu over a page view on the next main run loop turn, outside the page call that
/// asked for it (AppKit's menu tracking runs its own loop), and resumes once the menu closes.
@MainActor
enum PageMenuPresenter {
    /// Shows `menu` at `point` (in `view`'s top-down coordinates); a view in no window shows none.
    static func present(_ menu: NSMenu, at point: CGPoint, in view: NSView) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak view] in
                MainActor.assumeIsolated { // main-proof: a CFRunLoopGetMain() block runs on the main thread
                    // A view in no window cannot anchor a menu (AppKit raises): the page closed meanwhile.
                    if let view, view.window != nil {
                        let at = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
                        menu.popUp(positioning: nil, at: at, in: view)
                    }
                    continuation.resume()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}
