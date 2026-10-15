import Foundation
import Testing
@testable import CmuxBrowser

/// macOS's camera/microphone permission for cmux, faked: no test raises the OS prompt.
@MainActor
private final class FakeMediaAuthorization: BrowserMediaAuthorizationProviding {
    var statuses: [BrowserMediaDevice: BrowserMediaAuthorization]
    var grantOnRequest = true
    private(set) var requested: [BrowserMediaDevice] = []

    init(_ statuses: [BrowserMediaDevice: BrowserMediaAuthorization]) {
        self.statuses = statuses
    }

    func authorization(for device: BrowserMediaDevice) -> BrowserMediaAuthorization {
        statuses[device] ?? .authorized
    }

    func requestAccess(for device: BrowserMediaDevice) async -> Bool {
        requested.append(device)
        statuses[device] = grantOnRequest ? .authorized : .denied
        return grantOnRequest
    }
}

@Suite("Media authorization gate")
struct BrowserMediaAuthorizationGateTests {
    @Test func managedWinsOverBlockedWhichWinsOverAsk() {
        let both: [BrowserMediaDevice] = [.camera, .microphone]
        #expect(BrowserMediaAuthorizationGate.evaluate(both) { $0 == .camera ? .denied : .restricted } == .managed([.microphone]))
        #expect(BrowserMediaAuthorizationGate.evaluate(both) { $0 == .camera ? .denied : .authorized } == .blocked([.camera]))
        #expect(BrowserMediaAuthorizationGate.evaluate(both) { $0 == .camera ? .notDetermined : .authorized } == .ask(needsRequest: [.camera]))
        #expect(BrowserMediaAuthorizationGate.evaluate(both) { _ in .authorized } == .ask(needsRequest: []))
    }

    @Test func systemSettingsLinksPointAtThePrivacyPanes() {
        #expect(BrowserMediaDevice.camera.systemSettingsURL.absoluteString.hasSuffix("?Privacy_Camera"))
        #expect(BrowserMediaDevice.microphone.systemSettingsURL.absoluteString.hasSuffix("?Privacy_Microphone"))
        #expect(BrowserMediaDevice(.camera) == .camera)
        #expect(BrowserMediaDevice(.clipboardRead) == nil)
    }
}

@Suite("Permission coordinator and macOS camera/microphone access") @MainActor
struct BrowserPagePermissionCoordinatorMediaTests {
    private let origin = URL(string: "https://meet.example.com")!
    private let profile = UUID()

    private func make(
        _ media: FakeMediaAuthorization,
        opened: @escaping (URL) -> Void = { _ in }
    ) -> (BrowserPagePermissionCoordinator, BrowserPermissionPromptQueue, BrowserSitePermissionStore) {
        let queue = BrowserPermissionPromptQueue()
        let store = BrowserSitePermissionStore(fileURL: nil)
        let coordinator = BrowserPagePermissionCoordinator(
            queue: queue, store: { _ in store }, mediaAuthorization: media, openSystemSettings: opened
        )
        return (coordinator, queue, store)
    }

    private func request(_ kinds: [BrowserPagePermissionRequest.Kind]) -> BrowserPagePermissionRequest {
        BrowserPagePermissionRequest(kinds: kinds, origin: origin)
    }

    /// Starts a decision and answers the strip it shows (if any) with `answer`.
    private func decide(
        _ coordinator: BrowserPagePermissionCoordinator,
        _ queue: BrowserPermissionPromptQueue,
        _ kinds: [BrowserPagePermissionRequest.Kind],
        answer: BrowserPermissionPromptAnswer
    ) async -> BrowserPagePermissionCoordinator.Outcome {
        let task = Task { @MainActor in
            await coordinator.decideDetailed(request(kinds), profileID: profile, sessionGrants: nil)
        }
        for _ in 0..<20 where queue.current == nil {
            await Task.yield()
        }
        if let shown = queue.current { queue.answer(shown.id, with: answer) }
        return await task.value
    }

    @Test func deniedDeviceDeniesAtOnceAndShowsTheSystemStripOncePerPage() async {
        var opened: [URL] = []
        let media = FakeMediaAuthorization([.camera: .denied])
        let (coordinator, queue, _) = make(media) { opened.append($0) }
        let first = await coordinator.decideDetailed(request([.camera, .microphone]), profileID: profile, sessionGrants: nil)
        #expect(first == .init(.deny, isOneTime: true))
        #expect(queue.current?.style == .systemBlocked)
        #expect(queue.current?.kinds == [.camera, .microphone])
        // Asking again on the same page: denied, no second strip.
        _ = await coordinator.decideDetailed(request([.camera]), profileID: profile, sessionGrants: nil)
        #expect(queue.prompts.count == 1)
        queue.answer(queue.current!.id, with: .openSystemSettings)
        #expect(opened == [BrowserMediaDevice.camera.systemSettingsURL])
        #expect(media.requested.isEmpty)
        // After a new page load (back from System Settings), the strip may show again.
        coordinator.pageWillLoad()
        _ = await coordinator.decideDetailed(request([.camera]), profileID: profile, sessionGrants: nil)
        #expect(queue.current?.style == .systemBlocked)
    }

    @Test func managedDeviceShowsTheManagedStripAndNeverOpensSettings() async {
        var opened: [URL] = []
        let (coordinator, queue, _) = make(FakeMediaAuthorization([.microphone: .restricted])) { opened.append($0) }
        let outcome = await coordinator.decideDetailed(request([.microphone]), profileID: profile, sessionGrants: nil)
        #expect(outcome == .init(.deny, isOneTime: true))
        #expect(queue.current?.style == .systemManaged)
        queue.answer(queue.current!.id, with: .notNow)
        #expect(opened.isEmpty)
    }

    @Test func notDeterminedAsksMacOSOnlyAfterTheSiteIsAllowed() async {
        let media = FakeMediaAuthorization([.camera: .notDetermined])
        let (coordinator, queue, store) = make(media)
        let outcome = await decide(coordinator, queue, [.camera], answer: .allowAndRemember)
        #expect(outcome == .init(.grant))
        #expect(media.requested == [.camera])
        #expect(store.setting(.camera, for: origin) == .allow)
    }

    @Test func macOSRefusingDeniesAndRemembersNothing() async {
        let media = FakeMediaAuthorization([.camera: .notDetermined])
        media.grantOnRequest = false
        let (coordinator, queue, store) = make(media)
        let outcome = await decide(coordinator, queue, [.camera], answer: .allowAndRemember)
        #expect(outcome == .init(.deny, isOneTime: true))
        #expect(store.setting(.camera, for: origin) == nil)
    }

    @Test func blockingTheSiteNeverAsksMacOS() async {
        let media = FakeMediaAuthorization([.camera: .notDetermined])
        let (coordinator, queue, _) = make(media)
        _ = await decide(coordinator, queue, [.camera], answer: .block)
        #expect(media.requested.isEmpty)
    }

    @Test func rememberedAllowStillMeetsMacOSDenial() async {
        let media = FakeMediaAuthorization([.camera: .denied])
        let (coordinator, queue, store) = make(media)
        store.set(.allow, for: [.camera], at: origin)
        let outcome = await coordinator.decideDetailed(request([.camera]), profileID: profile, sessionGrants: nil)
        #expect(outcome == .init(.deny, isOneTime: true))
        #expect(queue.current?.style == .systemBlocked)
    }

    @Test func clipboardIsNotAMediaDevice() async {
        let media = FakeMediaAuthorization([.camera: .denied])
        let (coordinator, queue, _) = make(media)
        let outcome = await decide(coordinator, queue, [.clipboardRead], answer: .allowOnce)
        #expect(outcome == .init(.grant, isOneTime: true))
        #expect(media.requested.isEmpty)
    }
}
