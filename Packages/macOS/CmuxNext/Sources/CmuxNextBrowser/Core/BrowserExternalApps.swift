public import Foundation
import AppKit
import CmuxNextCompat

/// Opens a page's links to other apps (mailto:, tel:, an app's own scheme)
/// in their default app (cx-d0d.22). In DEBUG builds launched with
/// `CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1` it records them instead, so a
/// live test never starts Mail (`debug.browser.external_opens`).
@MainActor
public final class BrowserExternalApps {
    public static let shared = BrowserExternalApps()

    #if DEBUG
    /// The URLs a recording build would have opened, oldest first.
    public private(set) var recorded: [URL] = []
    private let records = ProcessInfo.processInfo.environment["CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS"] == "1"

    public func clearRecorded() {
        recorded.removeAll()
    }
    #endif

    func launch(_ url: URL) {
        #if DEBUG
        if records {
            recorded.append(url)
            return
        }
        #endif
        NSWorkspace.shared.openInBackground(url)
    }
}
