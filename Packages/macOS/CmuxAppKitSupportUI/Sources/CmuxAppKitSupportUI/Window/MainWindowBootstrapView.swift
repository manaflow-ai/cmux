public import SwiftUI
import AppKit

/// A zero-size scene-priming view that creates, names, and immediately closes the
/// app's bootstrap window.
///
/// SwiftUI's `WindowGroup` requires at least one window at launch. This view backs
/// that throwaway window: it stamps the `cmux.bootstrap` identifier, marks it
/// non-restorable, and orders it out then closes it on the next main-actor turn so
/// it never becomes visible or participates in window restoration.
public struct MainWindowBootstrapView: View {
    /// Creates the bootstrap view.
    public init() {}

    public var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(WindowAccessor { window in
                window.identifier = NSUserInterfaceItemIdentifier("cmux.bootstrap")
                window.isRestorable = false
                window.orderOut(nil)
                Task { @MainActor [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
            })
    }
}
