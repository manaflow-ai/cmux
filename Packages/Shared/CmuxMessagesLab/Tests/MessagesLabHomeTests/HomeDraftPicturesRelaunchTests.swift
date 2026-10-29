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

    /// Another view of the same conversation on the same store: what a switch to another chat
    /// and back builds (the store lives on; only the view goes).
    private func reopen(_ launch: Launch) async throws -> Launch {
        launch.view.stop()
        launch.window.close()
        let me = try #require(launch.store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: launch.store, conversation: Self.conversation, me: me, wake: NoWake(), replies: .streaming)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.projection.refresh()
        return Launch(store: launch.store, view: view, window: window)
    }

    /// A second, different picture.
    private func otherShot(_ launch: Launch) async throws -> LocalAttachment {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 30, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let shot = try await launch.store.prepareAttachment(data: try #require(rep.representation(using: .png, properties: [:])),
                                                            typeIdentifier: UTType.png.identifier)
        await launch.view.addDraftAttachment(shot)
        return shot
    }

    /// Types `more` after the draft, as a key in the field does (the text changes, then the host hears of it).
    private func append(_ more: String, in launch: Launch) {
        launch.view.controller.dispatch(.setDraft(launch.view.draftText + more))
        launch.view.projection.draftChanged()
    }

    /// Text, a picture, text, a picture, text: the order the person built it in.
    private func interleaved(_ launch: Launch) async throws -> (text: String, shots: [LocalAttachment]) {
        append("look at this", in: launch)
        let first = try await paste(launch)
        append("\nand then this one", in: launch)
        let second = try await otherShot(launch)
        append("\nwhich is right?", in: launch)
        let text = launch.view.draftText
        #expect(text == "look at this\u{FFFC}\nand then this one\u{FFFC}\nwhich is right?")
        #expect(launch.view.draftAttachments == [first, second])
        return (text, [first, second])
    }

    /// Lawrence 2026-10-23: "if i have text interleaved image, and i switch to diff messages, and
    /// switch back, then the ordering of images/text is broken". The draft came back as all the
    /// text, then every picture at the end.
    @Test func textInterleavedWithPicturesKeepsItsOrderAcrossAChatSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await launch(root)
        let draft = try await interleaved(first)
        let back = try await reopen(first)
        defer { back.quit() }
        await until { back.view.draftAttachments.count == draft.shots.count }
        #expect(back.view.draftAttachments == draft.shots, "both pictures are back, in order")
        #expect(back.view.draftText == draft.text, "each picture sits where it was in the text")
    }

    @Test func textInterleavedWithPicturesKeepsItsOrderAcrossARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-draft-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await launch(root)
        let draft = try await interleaved(first)
        first.quit()

        let second = try await launch(root)
        defer { second.quit() }
        await until { second.view.draftAttachments.count == draft.shots.count }
        #expect(second.view.draftAttachments == draft.shots)
        #expect(second.view.draftText == draft.text, "each picture sits where it was in the text")
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
