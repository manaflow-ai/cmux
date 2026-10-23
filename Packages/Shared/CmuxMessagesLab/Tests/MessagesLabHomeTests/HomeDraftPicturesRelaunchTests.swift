import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// A screenshot pasted in Home's message box is still there after Quit and
/// relaunch, with the text (Leo 2026-10-21: "my screenshots didnt get saved
/// in the draft when i closed the app"). The real view (`MessagesLabHomeView`)
/// over a real `HomeStore` with its cache, in an offscreen window; a relaunch
/// is a new store and a new view on the same cache and blob directory.
@MainActor @Suite(.serialized) struct HomeDraftPicturesRelaunchTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// One launch: the store, its view on the Chief's conversation, and the window.
    final class Launch {
        let store: HomeStore
        let view: MessagesLabHomeView
        let window: NSWindow

        init(store: HomeStore, view: MessagesLabHomeView, window: NSWindow) {
            self.store = store
            self.view = view
            self.window = window
        }

        /// Quit: the view goes, then the store writes its cache.
        @MainActor func quit() {
            view.stop()
            window.close()
            store.stop()
        }
    }

    private func launch(_ root: URL) async throws -> Launch {
        let store = HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: root.appendingPathComponent("blobs"),
                              cache: HomeCache(url: root.appendingPathComponent("home.json")), cacheWriteDelay: .zero)
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake(), replies: .streaming)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.projection.refresh()
        return Launch(store: store, view: view, window: window)
    }

    /// A small PNG, as a pasted screenshot arrives (bytes, not a file).
    private func screenshot() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func paste(_ launch: Launch) async throws -> LocalAttachment {
        let shot = try await launch.store.prepareAttachment(data: try screenshot(), typeIdentifier: UTType.png.identifier)
        await launch.view.addDraftAttachment(shot)
        return shot
    }

    @Test func aPastedScreenshotIsInTheFieldAfterARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await launch(root)
        first.view.controller.dispatch(.setDraft("what is this"))
        first.view.projection.draftChanged()
        let shot = try await paste(first)
        #expect(first.view.draftAttachments == [shot])
        first.quit()

        let second = try await launch(root)
        defer { second.quit() }
        await until { second.view.draftAttachments == [shot] }
        #expect(second.view.draftAttachments == [shot], "the screenshot's chip is back")
        #expect(second.view.draftText.contains("what is this"), "with the text")
    }

    @Test func aRemovedScreenshotStaysGoneAfterARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await launch(root)
        let shot = try await paste(first)
        first.view.removeDraftAttachment(shot.ref.hash)
        first.quit()

        let second = try await launch(root)
        defer { second.quit() }
        #expect(second.store.draftAttachments(for: Self.conversation).isEmpty, "nothing for the field to restore")
        #expect(second.view.draftAttachments.isEmpty)
    }

    /// Return pressed while the last launch's chips are still coming back: the
    /// send waits for the last one and takes them all, so none is lost.
    @Test func aSendDuringTheRestoreTakesEveryScreenshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await launch(root)
        first.view.controller.dispatch(.setDraft("two shots"))
        first.view.projection.draftChanged()
        _ = try await paste(first)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 30, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let other = try await first.store.prepareAttachment(data: try #require(rep.representation(using: .png, properties: [:])),
                                                            typeIdentifier: UTType.png.identifier)
        await first.view.addDraftAttachment(other)
        #expect(first.store.draftAttachments(for: Self.conversation).count == 2)
        first.quit()

        let second = try await launch(root)
        defer { second.quit() }
        #expect(second.view.draftAttachments.isEmpty, "Return comes before any chip is back")
        #expect(second.view.sendDraft() != nil, "held for the chips")
        let pictures: @MainActor () -> Int = {
            second.store.transcript(for: Self.conversation).map { $0.parts.filter { if case .attachment = $0 { true } else { false } }.count }.max() ?? 0
        }
        await until { pictures() == 2 }
        #expect(pictures() == 2, "one message with both screenshots")
        #expect(second.view.draftAttachments.isEmpty)
        #expect(second.store.draftAttachments(for: Self.conversation).isEmpty)
    }

    @Test func aSentScreenshotDoesNotComeBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await launch(root)
        _ = try await paste(first)
        #expect(first.view.sendDraft() == nil)
        #expect(first.store.draftAttachments(for: Self.conversation).isEmpty)
        first.quit()

        let second = try await launch(root)
        defer { second.quit() }
        #expect(second.store.draftAttachments(for: Self.conversation).isEmpty, "nothing for the field to restore")
        #expect(second.view.draftAttachments.isEmpty)
    }
}
