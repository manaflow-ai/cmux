#if canImport(AppKit)

public import AppKit
internal import SwiftUI

/// Presents the Acknowledgments (Third-Party Licenses) window (`cmux.licenses`).
///
/// The controller reuses ``ReleasingWindowController``'s recreate-on-reopen
/// teardown and builds the fixed 500x480 titled/closable/miniaturizable/resizable
/// window hosting ``AcknowledgmentsView``. Unlike the About window it applies no
/// titlebar-debug options and no window-chrome decoration, matching the original
/// app-target controller. Its localized title and "not found" fallback are
/// injected so they resolve against the app bundle's catalog.
public final class AcknowledgmentsWindowController: ReleasingWindowController {
    private let strings: AcknowledgmentsStrings

    /// Creates the controller. The window is built lazily on first presentation.
    ///
    /// - Parameter strings: Localized title and licenses-not-found fallback text.
    public init(strings: AcknowledgmentsStrings) {
        self.strings = strings
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = strings.windowTitle
        window.identifier = NSUserInterfaceItemIdentifier("cmux.licenses")
        window.center()
        window.contentView = NSHostingView(rootView: AcknowledgmentsView(notFound: strings.notFound))
        return window
    }

    /// Presents the Acknowledgments window, creating it on first use.
    public func show() {
        showManagedWindow(centerWhenHidden: false)
    }
}

#endif
