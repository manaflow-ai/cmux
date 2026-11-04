import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextWakeups
import CoreGraphics
import Foundation
import Testing

/// With nothing set, a hibernating page keeps its picture compressed (JPEG in its own store), so every hibernated tab
/// wakes to its picture (#23083). This pins the default path, whichever switch or Debug toggle decides it.
@MainActor @Suite(.serialized)
struct HibernationDefaultPictureTests {
    @Test func aHibernatingPagesPictureIsCompressedByDefault() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(), deadlines: services.mainDeadlines)
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        hibernation.capture = { _ in image }
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
        defer { tab.close() }
        let picture = await hibernation.snapshot(tab, key: "a")
        #expect(picture?.isEncoded == true, "the default keeps a hibernated page's picture compressed")
    }
}
