import AppKit
import WebKit

extension WKWebView {
    func cmuxOwnsKeyEvent(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window ?? window,
              eventWindow === window,
              let responder = eventWindow.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    nonisolated private static var cmuxSetPageMutedSelector: Selector {
        NSSelectorFromString("_setPageMuted:")
    }

    nonisolated private static var cmuxMediaMutedStateAudio: Int {
        1 << 0
    }

    @discardableResult
    func cmuxSetPageAudioMuted(_ muted: Bool) -> Bool {
        let selector = Self.cmuxSetPageMutedSelector
        guard responds(to: selector),
              let implementation = method(for: selector) else {
            return false
        }

        typealias SetPageMutedFunction = @convention(c) (AnyObject, Selector, Int) -> Void
        let function = unsafeBitCast(implementation, to: SetPageMutedFunction.self)
        function(self, selector, muted ? Self.cmuxMediaMutedStateAudio : 0)
        return true
    }

    var cmuxIsElementFullscreenActiveOrTransitioning: Bool {
        switch fullscreenState {
        case .notInFullscreen:
            return false
        case .enteringFullscreen, .inFullscreen, .exitingFullscreen:
            return true
        @unknown default:
            return true
        }
    }

    func cmuxIsManagedByExternalFullscreenWindow(relativeTo expectedWindow: NSWindow?) -> Bool {
        guard cmuxIsElementFullscreenActiveOrTransitioning else { return false }
        guard let expectedWindow else { return true }
        return window !== expectedWindow
    }
}
