import Foundation
import Testing
@testable import CmuxNextBrowser

/// Lawrence (2026-10-23): "making splits in general has laggy animation, even more laggy if there
/// are CEF chromium views involved". A Chromium page is a child window the fork resizes with its
/// pane. In Chromium 154 each resize of that window calls `CATransactionCoordinator::Synchronize`
/// (`NativeWidgetNSWindowBridge::UpdateWindowGeometry`), whose pre-commit handler holds the app's
/// Core Animation commit, on the app's main thread, until Chromium has a frame at the new size or
/// 500 ms pass: every frame of a split or close that resized a page waited for the page's relayout
/// and raster. `AsyncLiveResize` skips that wait (the page shows its last frame over the page's
/// own backdrop until the new one lands). A fork with the resize-sync API (27) waits up to a
/// deadline the app sets instead, so it keeps the wait path.
@Suite struct CEFPageResizeCommitSwitchTests {
    static func features(forkAPIVersion: Int32) -> [String] {
        CEFSwitches.current(forkAPIVersion: forkAPIVersion, bundleIdentifier: "com.cmuxterm.app.next", environment: [:]).arguments
            .filter { $0.hasPrefix("enable-features=") }
            .flatMap { $0.dropFirst("enable-features=".count).split(separator: ",").map(String.init) }
    }

    @Test(arguments: [Int32(7), 26])
    func aPageResizeDoesNotHoldTheAppsCommit(forkAPIVersion: Int32) {
        #expect(Self.features(forkAPIVersion: forkAPIVersion).contains("AsyncLiveResize"))
    }

    @Test func aForkWithResizeSyncKeepsChromiumsBoundedWait() {
        #expect(!Self.features(forkAPIVersion: 27).contains("AsyncLiveResize"))
    }
}
