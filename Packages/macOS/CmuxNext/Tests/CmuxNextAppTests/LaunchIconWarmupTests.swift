import CmuxNextIcons
import Foundation
import Testing

/// p08-startup-039: the icon pack and catalog (367 KB of JSON, a `swift_once` each) decode on the
/// launch's icon warm-up thread, not on main at the first tab or sidebar icon before the first frame.
@MainActor @Suite("Launch icon warm-up")
struct LaunchIconWarmupTests {
    private nonisolated struct Decoded: Sendable {
        let onMain: Bool
        let threadName: String?
        let packIcons: Int
        let catalogEntries: Int
    }

    @Test("The icon warm-up decodes the shipped pack and the catalog off the main thread")
    func decodesOffMain() async {
        let decoded = await withCheckedContinuation { (continuation: CheckedContinuation<Decoded, Never>) in
            IconPack.decodeBundledInBackground {
                continuation.resume(returning: Decoded(
                    onMain: Thread.isMainThread,
                    threadName: Thread.current.name,
                    packIcons: IconPack.bundled.icons.count,
                    catalogEntries: IconCatalog.bundled.entries.count
                ))
            }
        }
        #expect(!decoded.onMain)
        #expect(decoded.threadName == "cmux-next icon warm-up")
        #expect(decoded.packIcons > 0)
        #expect(decoded.catalogEntries > 0)
    }
}
