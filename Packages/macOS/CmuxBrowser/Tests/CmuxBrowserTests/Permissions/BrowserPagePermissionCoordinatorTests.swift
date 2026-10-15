import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Page permission coordinator") @MainActor
struct BrowserPagePermissionCoordinatorTests {
    private let origin = URL(string: "https://meet.example.com/room")!
    private let profile = UUID()

    private func makeCoordinator() -> (BrowserPagePermissionCoordinator, BrowserPermissionPromptQueue, BrowserSitePermissionStore) {
        let queue = BrowserPermissionPromptQueue()
        let store = BrowserSitePermissionStore(fileURL: nil)
        return (BrowserPagePermissionCoordinator(queue: queue, store: { _ in store }), queue, store)
    }

    /// Starts `decide`, then answers the prompt it shows.
    private func decide(
        _ coordinator: BrowserPagePermissionCoordinator,
        _ queue: BrowserPermissionPromptQueue,
        kinds: [BrowserPagePermissionRequest.Kind],
        answer: BrowserPermissionPromptAnswer?
    ) async -> (BrowserPagePermissionDecision, BrowserPermissionPrompt?) {
        let task = Task { @MainActor in
            await coordinator.decide(BrowserPagePermissionRequest(kinds: kinds, origin: origin), profileID: profile, sessionGrants: nil)
        }
        for _ in 0..<20 where queue.current == nil {
            await Task.yield()
        }
        let shown = queue.current
        if let shown {
            if let answer { queue.answer(shown.id, with: answer) } else { queue.cancelAll() }
        }
        return (await task.value, shown)
    }

    @Test func allowWhileVisitingIsRememberedAndSkipsTheNextPrompt() async {
        let (coordinator, queue, store) = makeCoordinator()
        let (first, shown) = await decide(coordinator, queue, kinds: [.camera, .microphone], answer: .allowAndRemember)
        #expect(first == .grant)
        #expect(shown?.kinds == [.camera, .microphone])
        #expect(shown?.style == .captureDevices)
        #expect(store.setting(.camera, for: origin) == .allow)
        let (second, again) = await decide(coordinator, queue, kinds: [.camera], answer: nil)
        #expect(second == .grant)
        #expect(again == nil)
    }

    @Test func allowOnceGrantsWithoutRemembering() async {
        let (coordinator, queue, store) = makeCoordinator()
        let (decision, _) = await decide(coordinator, queue, kinds: [.microphone], answer: .allowOnce)
        #expect(decision == .grant)
        #expect(store.setting(.microphone, for: origin) == nil)
    }

    @Test func blockIsRememberedAndDeniesLaterWithoutAsking() async {
        let (coordinator, queue, store) = makeCoordinator()
        let (decision, shown) = await decide(coordinator, queue, kinds: [.clipboardRead], answer: .block)
        #expect(decision == .deny)
        #expect(shown?.style == .blockOrAllow)
        #expect(store.setting(.clipboardRead, for: origin) == .block)
        let (later, again) = await decide(coordinator, queue, kinds: [.clipboardRead], answer: nil)
        #expect(later == .deny)
        #expect(again == nil)
    }

    @Test func endedUnansweredIsNoAnswerAndStoresNothing() async {
        let (coordinator, queue, store) = makeCoordinator()
        let (decision, shown) = await decide(coordinator, queue, kinds: [.camera], answer: nil)
        #expect(shown != nil)
        #expect(decision == .prompt)
        #expect(store.setting(.camera, for: origin) == nil)
    }

    @Test func policyDenialsAndSessionGrantsNeverPrompt() async {
        let (coordinator, queue, _) = makeCoordinator()
        let geo = await coordinator.decide(BrowserPagePermissionRequest(kinds: [.geolocation], origin: origin), profileID: profile, sessionGrants: nil)
        #expect(geo == .deny)
        let session = await coordinator.decide(BrowserPagePermissionRequest(kinds: [.camera], origin: origin), profileID: profile, sessionGrants: ["camera"])
        #expect(session == .grant)
        #expect(queue.current == nil)
    }
}

@Suite("Permission prompt queue") @MainActor
struct BrowserPermissionPromptQueueTests {
    private let origin = URL(string: "https://a.example:8443")!

    @Test func showsOneAtATimeInOrderAndEndsEachOnce() {
        let queue = BrowserPermissionPromptQueue()
        var ended: [String] = []
        let first = BrowserPermissionPrompt(kinds: [.camera], origin: origin)
        let second = BrowserPermissionPrompt(kinds: [.clipboardRead], origin: origin)
        queue.enqueue(first) { answer in ended.append("first=" + (answer.map { "\($0)" } ?? "none")) }
        queue.enqueue(second) { answer in ended.append("second=" + (answer.map { "\($0)" } ?? "none")) }
        #expect(queue.current == first)
        #expect(queue.answer(first.id, with: .allowOnce))
        #expect(!queue.answer(first.id, with: .block))
        #expect(queue.current == second)
        queue.cancelAll()
        #expect(queue.current == nil)
        #expect(ended == ["first=allowOnce", "second=none"])
    }

    @Test func displayOriginOmitsSchemeAndDefaultPort() {
        #expect(BrowserPermissionPrompt(kinds: [.camera], origin: origin).displayOrigin == "a.example:8443")
        #expect(BrowserPermissionPrompt(kinds: [.camera], origin: URL(string: "https://b.example:443/x")!).displayOrigin == "b.example")
    }
}

@Suite("Site permission store") @MainActor
struct BrowserSitePermissionStoreTests {
    @Test func originKeyIsSchemeHostAndNonDefaultPortForWebOnly() {
        #expect(BrowserSitePermissionStore.originKey(for: URL(string: "https://A.example/path?q")) == "https://a.example")
        #expect(BrowserSitePermissionStore.originKey(for: URL(string: "https://a.example:443")) == "https://a.example")
        #expect(BrowserSitePermissionStore.originKey(for: URL(string: "http://a.example:8080")) == "http://a.example:8080")
        #expect(BrowserSitePermissionStore.originKey(for: URL(string: "file:///tmp/x.html")) == nil)
        #expect(BrowserSitePermissionStore.originKey(for: URL(string: "data:text/html,x")) == nil)
    }

    @Test func answersPersistPerOriginAndResetClearsThem() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-site-perms-\(UUID().uuidString)/\(BrowserSitePermissionStore.fileName)")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let a = URL(string: "https://a.example")!, b = URL(string: "https://b.example")!
        let store = BrowserSitePermissionStore(fileURL: file)
        store.set(.allow, for: [.camera, .microphone], at: a)
        store.set(.block, for: [.camera], at: b)
        let reloaded = BrowserSitePermissionStore(fileURL: file)
        #expect(reloaded.setting(.microphone, for: a) == .allow)
        #expect(reloaded.setting(.camera, for: b) == .block)
        #expect(reloaded.setting(.camera, for: URL(string: "http://a.example")) == nil)
        reloaded.reset(origin: a)
        #expect(reloaded.setting(.camera, for: a) == nil)
        reloaded.reset()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
