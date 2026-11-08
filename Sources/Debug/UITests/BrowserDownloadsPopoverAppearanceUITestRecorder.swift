#if DEBUG
import SwiftUI

/// Debug-only bridge that records the real popover window and SwiftUI color scheme.
struct BrowserDownloadsPopoverAppearanceUITestRecorder: View {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        let support = BrowserDownloadsPopoverAppearanceUITestSupport()
        if support.isEnabled {
            BrowserDownloadsPopoverAppearanceWindowAccessor { window in
                support.record(window: window, contentColorScheme: colorScheme)
            }
        }
    }
}
#endif
