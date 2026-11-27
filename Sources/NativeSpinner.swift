#if DEBUG
import AppKit
import SwiftUI

/// AppKit `NSProgressIndicator` wrapped for the gallery comparison.
struct NativeSpinner: NSViewRepresentable {
    let threaded: Bool
    var controlSize: NSControl.ControlSize = .small

    func makeNSView(context: Context) -> NSProgressIndicator {
        let view = NSProgressIndicator()
        view.style = .spinning
        view.controlSize = controlSize
        view.isIndeterminate = true
        view.isDisplayedWhenStopped = false
        view.usesThreadedAnimation = threaded
        view.startAnimation(nil)
        return view
    }

    func updateNSView(_ view: NSProgressIndicator, context: Context) {
        view.controlSize = controlSize
        view.usesThreadedAnimation = threaded
        view.startAnimation(nil)
    }
}
#endif
