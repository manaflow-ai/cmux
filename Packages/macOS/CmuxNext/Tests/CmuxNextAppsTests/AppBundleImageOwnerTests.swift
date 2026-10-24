import AppKit
@testable import CmuxNextApps
import Foundation
import Testing

/// Decoded app bundle images belong to the ``AppsClient`` (``AppsClient/bundleImages``), not to the
/// process: every mount of one client (every window's sidebar section, pane page and customization
/// preview of the App's one client) shares one cache, a second client (a test's) keeps its own, and
/// an image decodes once per cache.
@MainActor
struct AppBundleImageOwnerTests {
    /// A supervisor that is never reachable: mounts show the disconnected reason and send nothing.
    private final class OfflineTransport: AppsTransport {
        let availability = AppsAvailability.unavailable(.notConnected)
        var onEvent: ((AppsTransportEvent) -> Void)?
        private static let refusal = AppsTransportError(message: "offline")

        func start() {}
        func list() async throws(AppsTransportError) -> AppsListReply { throw Self.refusal }
        func set(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppRecord {
            throw Self.refusal
        }
        func mount(app: String, interface: String, mountID: String, context: AppJSON) async throws(AppsTransportError) {}
        func unmount(mountID: String) async throws(AppsTransportError) {}
        func dispatch(mountID: String, node: String, event: String, payload: AppJSON) async throws(AppsTransportError) {}
        func run(app: String, op: String, args: AppJSON, origin: AppOrigin, idempotencyKey: String) async throws(AppsTransportError) -> AppJSON {
            throw Self.refusal
        }
        func logs(app: String, follow: Bool) async throws(AppsTransportError) -> [AppLogLine] { [] }
    }

    private static func section(_ id: String) -> AppImplementation {
        AppImplementation(interface: AppImplementation.section, id: id)
    }

    /// A bundle directory holding one 4x4 PNG, `icon.png`.
    private static func bundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-app-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "icon.png"))
        return directory
    }

    @Test func everyMountOfAClientSharesItsImages() {
        let client = AppsClient(transport: OfflineTransport())
        let sidebar = client.mount("app.one", implementation: Self.section("a"), surface: "sidebarSection")
        let pane = client.mount("app.two", implementation: Self.section("b"), surface: "pane")
        #expect(sidebar.bundleImages === client.bundleImages)
        #expect(pane.bundleImages === client.bundleImages, "two mounts of one client decode their images apart")
        let other = AppsClient(transport: OfflineTransport())
        #expect(other.bundleImages !== client.bundleImages, "two clients share one cache")
    }

    @Test func anImageDecodesOncePerCacheAndStaysInsideItsBundle() throws {
        let directory = try Self.bundle()
        defer { try? FileManager.default.removeItem(at: directory) }
        let images = AppBundleImageCache()
        let icon = try #require(images.image(path: "icon.png", in: directory))
        #expect(images.image(path: "icon.png", in: directory) === icon, "the image decoded again")
        #expect(AppBundleImageCache().image(path: "icon.png", in: directory) !== icon, "a second cache read the first cache's image")
        #expect(images.image(path: "../icon.png", in: directory) == nil)
        #expect(images.image(path: directory.appending(path: "icon.png").path, in: directory) == nil)
    }
}
