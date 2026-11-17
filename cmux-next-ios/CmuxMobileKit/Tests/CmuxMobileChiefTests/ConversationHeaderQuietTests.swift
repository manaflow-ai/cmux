import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief
#if os(iOS)
import CmuxConversationUI
import QuartzCore
import UIKit
#endif

/// A conversation's link as a test drives it: up, down and up again, with no Mac.
final class DrivenLinkBackend: ConversationBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<ConversationBackendEvent>.Continuation?
    static let info = ConversationInfo(id: "c-driven", title: "Ops", kind: .direct,
                                       participants: [ChiefIdentity.standard.me, ChiefIdentity.standard.chief])

    func events() -> AsyncStream<ConversationBackendEvent> {
        let (stream, continuation) = AsyncStream<ConversationBackendEvent>.makeStream(bufferingPolicy: .unbounded)
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func up() { yield(.connected(info: Self.info, meID: ChiefIdentity.standard.meID, lagged: false)) }
    func down() { yield(.disconnected(reason: "link dropped")) }
    private func yield(_ event: ConversationBackendEvent) { _ = lock.withLock { continuation?.yield(event) } }

    private var error: ConversationBackendError { ConversationBackendError(code: -1, message: "offline") }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(messages: [], hasMore: false)
    }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage { throw error }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { throw error }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { throw error }
    func unsend(messageID: String) async throws -> ConversationMessage { throw error }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { throw error }
    func close() { lock.withLock { continuation?.finish() } }
}

@MainActor
@Suite struct ConversationHeaderQuietTests {
    struct Offline: Error {}

    /// Waits for `condition`, at most `limit` (a bounded test wait, not a sync).
    private func eventually(_ limit: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + limit
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aPendingFirstOpenShowsItsConversationOnceTheBoundPasses() async {
        // An empty kept conversation is not shown on its own (``MacConversationScreen/shownKept``):
        // past the bound it must become the loader's session, or the screen keeps its spinner.
        let loader = MacConversationLoader(quiet: .milliseconds(30))
        let kept = ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
        let (gate, open) = AsyncStream<Void>.makeStream()
        let load = Task { @MainActor in
            await loader.load({
                for await _ in gate {}
                throw Offline()
            }, fallback: kept, tryAgain: {})
        }
        #expect(await eventually { loader.isStale })
        #expect(loader.session === kept)
        open.finish()
        await load.value
        #expect(loader.session === kept)
    }

    #if os(iOS)
    private static func label(_ text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.text == text { return label }
        for sub in view.subviews { if let found = label(text, in: sub) { return found } }
        return nil
    }

    @Test func aHeaderOpenedDuringALongOutageSaysSo() async {
        let backend = DrivenLinkBackend()
        let store = ConversationStore(backend: backend)
        store.connectionQuietDelay = .milliseconds(20)
        store.start()
        defer { store.stop() }
        backend.down()
        #expect(await eventually { store.connectionNoticeDue })

        // The screen opens after the bound passed: no connection callback comes for it.
        let controller = ConversationViewController(store: store)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        #expect(Self.label("Connecting…", in: controller.view) != nil)
    }

    /// The simulator read-back of Leo's flow (2026-11-16) with no paired Mac: a drop that comes
    /// back under 10 s says nothing, one past 10 s says "Connecting…" once, and back is silent.
    /// Screenshots go out as test attachments (kit-attachments/).
    @Test func readBackTheThreeStatesOfAReconnect() async throws {
        let backend = DrivenLinkBackend()
        let store = ConversationStore(backend: backend)
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let controller = ConversationViewController(store: store)
        let window = UIWindow(frame: bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            store.stop()
        }
        var log: [String] = []
        let started = CACurrentMediaTime()
        func capture(_ name: String) {
            let shown = Self.label("Connecting…", in: controller.view).map { $0.alpha > 0 } ?? false
            log.append("\(name) t=\(Int((CACurrentMediaTime() - started) * 1000))ms connecting_line=\(shown)")
            // The layer tree itself: a test host's window has no scene, so drawHierarchy waits for a
            // screen commit that never comes (a blank image and a ~13 s stall on the main actor).
            controller.view.frame = bounds
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
                UIColor.systemBackground.setFill()
                context.fill(bounds)
                controller.view.layer.render(in: context.cgContext)
            }
            if let png = image.pngData() { Attachment.record(Array(png), named: "\(name).png") }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(400)) } // test: the line's 0.25 s fade

        backend.up()
        #expect(await eventually { store.connection == .connected })

        // 1. Down, back within the bound: nothing at the top.
        backend.down()
        #expect(await eventually { store.connection == .reconnecting })
        try await Task.sleep(for: .seconds(3)) // test: a 3 s outage, under the 10 s bound
        await settle()
        capture("1-down-3s-silent")
        #expect(Self.label("Connecting…", in: controller.view) == nil)
        backend.up()
        #expect(await eventually { store.connection == .connected })

        // 2. Down past the bound: one calm line.
        backend.down()
        try await Task.sleep(for: .seconds(10.5)) // test: past QuietStatusGate.threshold
        await settle()
        capture("2-down-past-10s-one-line")
        #expect(store.connectionNoticeDue)
        #expect(Self.label("Connecting…", in: controller.view) != nil)

        // 3. Back: silent again.
        backend.up()
        #expect(await eventually { store.connection == .connected })
        await settle()
        capture("3-back-silent")
        #expect(Self.label("Connecting…", in: controller.view) == nil)
        Attachment.record(log.joined(separator: "\n"), named: "reconnect-states.txt")
    }
    #endif
}
