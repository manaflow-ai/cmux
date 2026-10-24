@testable import CmuxNextDesign
import Foundation
import os
import Testing

/// A link download's folder work and its removal run off the main actor even when the Settings
/// page (main actor) awaits them. A plain async function in a NonisolatedNonsendingByDefault
/// target runs on its caller's actor, so `download`'s createDirectory and the page's removeItem
/// ran on main (PL-qos, 2026-10-24); `download` and `removeDownload` are `@concurrent`.
@MainActor
struct BackdropDownloadOffMainTests {
    struct Stop: Error {}

    @Test func theDownloadFolderIsMadeOffTheMainThread() async {
        let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        await #expect(throws: Stop.self) {
            _ = try await BackdropUserImages.download(URL(string: "https://example.com/sea.png")!) { _ in
                onMain.withLock { $0 = Thread.isMainThread }
                throw Stop()
            }
        }
        #expect(onMain.withLock { $0 } == false)
    }

    @Test func theDownloadFolderIsRemovedOffTheMainThread() async {
        let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let removed = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let file = URL(fileURLWithPath: "/tmp/cmux-background-test/download.png")
        await BackdropUserImages.removeDownload(file) { folder in
            onMain.withLock { $0 = Thread.isMainThread }
            removed.withLock { $0 = folder }
        }
        #expect(onMain.withLock { $0 } == false)
        #expect(removed.withLock { $0 }?.path == "/tmp/cmux-background-test")
    }
}
