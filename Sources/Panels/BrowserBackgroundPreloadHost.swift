import AppKit
import Foundation

@MainActor
enum BrowserBackgroundPreloadHost {
    @discardableResult
    static func attach(_ presentationView: NSView, to window: NSWindow) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        contentView.addSubview(presentationView)
        return contentView
    }

    /// Orders hidden preload windows on systems where Safari completion views
    /// tolerate the transition. macOS 27 asserts inside `NSRemoteView` when an
    /// alpha-zero WebKit host orders on screen while its completion service is
    /// detached, so the attached window stays ordered out on that OS. Hidden
    /// navigation still runs and the browser portal performs its existing
    /// first-visible geometry nudge when the web view reaches a real window.
    static func orderOnScreenIfSafe(
        _ window: NSWindow,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        guard operatingSystemVersion.majorVersion < 27 else { return }
        window.orderFrontRegardless()
    }
}
