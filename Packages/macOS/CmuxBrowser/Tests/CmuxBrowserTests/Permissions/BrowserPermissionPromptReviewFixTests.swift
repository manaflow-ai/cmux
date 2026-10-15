import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Permission prompt sharing, one-time grants and retired stores") @MainActor
struct BrowserPermissionPromptReviewFixTests {
    private let origin = URL(string: "https://meet.example.com")!

    private static func label(_ answer: BrowserPermissionPromptAnswer?) -> String {
        answer.map { "\($0)" } ?? "none"
    }

    @Test func identicalQuestionsShareOneBarAndOneAnswer() {
        let queue = BrowserPermissionPromptQueue()
        var answers: [String] = []
        queue.enqueue(BrowserPermissionPrompt(kinds: [.camera, .microphone], origin: origin)) { answers.append("a=" + Self.label($0)) }
        queue.enqueue(BrowserPermissionPrompt(kinds: [.microphone, .camera], origin: URL(string: "https://meet.example.com/other")!)) {
            answers.append("b=" + Self.label($0))
        }
        #expect(queue.prompts.count == 1)
        queue.answer(queue.current!.id, with: .allowOnce)
        #expect(answers == ["a=allowOnce", "b=allowOnce"])
        #expect(queue.current == nil)
    }

    @Test func differentOriginsOrKindsStaySeparateQuestions() {
        let queue = BrowserPermissionPromptQueue()
        queue.enqueue(BrowserPermissionPrompt(kinds: [.camera], origin: origin)) { _ in }
        queue.enqueue(BrowserPermissionPrompt(kinds: [.microphone], origin: origin)) { _ in }
        queue.enqueue(BrowserPermissionPrompt(kinds: [.camera], origin: URL(string: "https://other.example")!)) { _ in }
        #expect(queue.prompts.count == 3)
    }

    @Test func aReusedIdEndsTheNewQuestionUnanswered() {
        let queue = BrowserPermissionPromptQueue()
        let prompt = BrowserPermissionPrompt(kinds: [.camera], origin: origin)
        var second: String?
        queue.enqueue(prompt) { _ in }
        queue.enqueue(prompt) { second = Self.label($0) }
        #expect(second == "none")
        #expect(queue.prompts.count == 1)
    }

    @Test func clipboardAllowIsOneTimeAndOtherAllowsAreRemembered() {
        #expect(BrowserPermissionPrompt(kinds: [.clipboardRead], origin: origin).allowAnswer == .allowOnce)
        #expect(BrowserPermissionPrompt(kinds: [.clipboardRead], origin: origin).style == .blockOrAllow)
        #expect(BrowserPermissionPrompt(kinds: [.geolocation], origin: origin).allowAnswer == .allowAndRemember)
    }

    @Test func oneTimeAndSessionGrantsAreReportedSoTheEngineDoesNotKeepThem() async {
        let queue = BrowserPermissionPromptQueue()
        let store = BrowserSitePermissionStore(fileURL: nil)
        let coordinator = BrowserPagePermissionCoordinator(queue: queue, store: { _ in store })
        let request = BrowserPagePermissionRequest(kinds: [.camera], origin: origin)
        let profile = UUID()
        let session = await coordinator.decideDetailed(request, profileID: profile, sessionGrants: ["camera"])
        #expect(session == BrowserPagePermissionCoordinator.Outcome(.grant, isOneTime: true))
        let task = Task { @MainActor in await coordinator.decideDetailed(request, profileID: profile, sessionGrants: nil) }
        for _ in 0..<20 where queue.current == nil {
            await Task.yield()
        }
        queue.answer(queue.current!.id, with: .allowOnce)
        #expect(await task.value == BrowserPagePermissionCoordinator.Outcome(.grant, isOneTime: true))
        store.set(.allow, for: [.camera], at: origin)
        let remembered = await coordinator.decideDetailed(request, profileID: profile, sessionGrants: nil)
        #expect(remembered == BrowserPagePermissionCoordinator.Outcome(.grant, isOneTime: false))
    }

    @Test func onlyAnswersCmuxRemembersStaySavedInTheEngine() async {
        let queue = BrowserPermissionPromptQueue()
        let store = BrowserSitePermissionStore(fileURL: nil)
        let coordinator = BrowserPagePermissionCoordinator(queue: queue, store: { _ in store })
        let profile = UUID()
        let geo = BrowserPagePermissionRequest(kinds: [.geolocation], origin: origin)
        #expect(await coordinator.decideDetailed(geo, profileID: profile, sessionGrants: nil) == .init(.deny, isOneTime: true))
        #expect(await coordinator.decideDetailed(geo, profileID: profile, sessionGrants: ["camera"]) == .init(.deny, isOneTime: true))
        store.set(.block, for: [.camera], at: origin)
        let camera = BrowserPagePermissionRequest(kinds: [.camera], origin: origin)
        #expect(await coordinator.decideDetailed(camera, profileID: profile, sessionGrants: nil) == .init(.deny, isOneTime: false))
    }

    @Test func panTiltZoomFoldsIntoCameraButAloneIsItsOwnKind() {
        #expect(BrowserChromiumPermissionRequest([.camera, .cameraPanTiltZoom]).pageKinds == [.camera])
        #expect(BrowserChromiumPermissionRequest.cameraPanTiltZoom.pageKinds == [.other("camera-pan-tilt-zoom")])
        #expect(BrowserChromiumPermissionRequest(cefPromptBits: UInt32(1) << 31).isEmpty)
        #expect(BrowserChromiumPermissionRequest(mediaAccess: 4) == .screenCapture)
    }

    @Test func askedKindsMapToTheShimContentSettingNames() {
        #expect(BrowserChromiumPermissionRequest.contentSettingType(for: .camera) == "camera")
        #expect(BrowserChromiumPermissionRequest.contentSettingType(for: .geolocation) == "location")
        #expect(BrowserChromiumPermissionRequest.contentSettingType(for: .clipboardRead) == "clipboard")
        #expect(BrowserChromiumPermissionRequest.contentSettingType(for: .other("x")) == nil)
        #expect(BrowserChromiumPermissionRequest.contentSettingType(forKindKey: "microphone") == "microphone")
        #expect(BrowserChromiumPermissionRequest.contentSettingType(forKindKey: "other:x") == nil)
    }

    @Test func resetReturnsForgottenAnswersAndARetiredStoreNeverRecreatesTheProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-retire-\(UUID().uuidString)/Chromium")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let registry = BrowserSitePermissionStoreRegistry(storage: BrowserChromiumProfileStorage(root: root))
        let profile = UUID()
        let store = registry.store(forProfileID: profile)
        store.set(.allow, for: [.camera], at: origin)
        #expect(registry.reset(profileID: profile).map(\.kind) == ["camera"])
        #expect(registry.store(forProfileID: profile) === store)
        registry.retire(profileID: profile)
        try? FileManager.default.removeItem(at: root)
        store.set(.block, for: [.camera], at: origin)
        registry.store(forProfileID: profile).set(.block, for: [.microphone], at: origin)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
