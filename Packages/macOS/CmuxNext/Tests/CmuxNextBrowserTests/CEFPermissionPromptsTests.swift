import Foundation
import Testing
@testable import CmuxNextBrowser

/// p01-process-062: every Chromium permission request is asked from data. Chromium's permission
/// bubble and screen picker are Views widgets a host-mode page never shows, so a request cmux does
/// not ask about waits until the page goes away. With the default-off feature
/// `chromiumPermissionPromptsFromData` the shim sends every `cef_permission_request_types_t` and
/// every screen share as PERMISSION_PROMPT (CEFShim/src/permission_prompt_policy.h, its cases in
/// scripts/cmux-next/test-shim-permission-prompts-cpp.sh); these cases cover what cmux asks and
/// answers.
@MainActor
@Suite struct CEFPermissionPromptsTests {
    private static let camera: Int64 = 1 << 2
    private static let microphone: Int64 = 1 << 12

    /// A media access request's bits as the shim sends them (`MediaPromptBits`).
    private static func media(_ bits: Int64) -> Int64 { bits << 32 }

    // MARK: Decoding

    @Test func locationAloneIsTheLocationQuestion() {
        #expect(CEFPermissionRequest(permissions: 1 << 8).kind == .location)
    }

    @Test func notificationsAloneIsTheNotificationsQuestion() {
        #expect(CEFPermissionRequest(permissions: 1 << 15).kind == .notifications)
    }

    @Test func cameraAndMicrophoneAreListedAsChromeGroupsThem() {
        let request = CEFPermissionRequest(permissions: Self.camera | Self.microphone)
        #expect(request.kind == .capabilities([.camera, .microphone]))
    }

    @Test func everyBitCEFDefinesHasAnItem() {
        for bit in 0..<29 {
            let kind = CEFPermissionRequest(permissions: Int64(1) << bit).kind
            #expect(kind != nil, "bit \(bit)")
        }
        #expect(CEFPermissionRequest(permissions: Int64(1) << 28).kind == .capabilities([.sensors]))
    }

    @Test func theTwoLocalNetworkBitsAreOneItem() {
        let request = CEFPermissionRequest(permissions: (1 << 25) | (1 << 26) | (1 << 27))
        #expect(request.kind == .capabilities([.localNetwork, .loopbackNetwork]))
    }

    @Test func anUnknownBitIsNotAsked() {
        #expect(CEFPermissionRequest(permissions: Int64(1) << 29).kind == nil)
        #expect(CEFPermissionRequest(permissions: Self.camera | (Int64(1) << 30)).kind == nil)
        #expect(CEFPermissionRequest(permissions: 0).kind == nil)
    }

    @Test func aScreenShareIsTheScreenQuestion() {
        #expect(CEFPermissionRequest(permissions: Self.media(1 << 3)).kind == .screen)
        #expect(CEFPermissionRequest(permissions: Self.media((1 << 3) | (1 << 2))).kind == .screen)
    }

    @Test func mediaWithoutScreenVideoOrWithADeviceIsNotAsked() {
        #expect(CEFPermissionRequest(permissions: Self.media(1 << 2)).kind == nil, "desktop audio alone")
        #expect(CEFPermissionRequest(permissions: Self.media((1 << 3) | (1 << 0))).kind == nil, "screen with the microphone")
        #expect(CEFPermissionRequest(permissions: Self.media(1 << 1)).kind == nil, "the camera through media access")
    }

    @Test func theEventCarriesWhichHandlerAsked() {
        let prompt = CEFPermissionRequest(permissions: 1 << 8)
        #expect(prompt.source == .prompt)
        #expect(prompt.bits == 1 << 8)
        let screen = CEFShimEvent(kind: 41, browser: 3, request: 8, a: Self.media(1 << 3), b: 0, s1: "https://a.test", s2: "")
        guard case .permissionPrompt(_, let token, let permissions, _) = screen else {
            Issue.record("not a permission prompt: \(screen)")
            return
        }
        let request = CEFPermissionRequest(permissions: permissions)
        #expect(token == 8)
        #expect(request.source == .media)
        #expect(request.bits == 1 << 3)
        #expect(request.kind == .screen)
    }

    // MARK: macOS access

    @Test func capturesNeedMacOSAccess() {
        #expect(CEFCapture.needed(by: .capabilities([.camera, .microphone])) == [.camera, .microphone])
        #expect(CEFCapture.needed(by: .capabilities([.cameraPanTiltZoom])) == [.camera])
        #expect(CEFCapture.needed(by: .screen) == [.screen])
        #expect(CEFCapture.needed(by: .capabilities([.clipboard, .location])).isEmpty)
        #expect(CEFCapture.needed(by: .location).isEmpty)
    }

    @Test func aSiteAllowedWhileMacOSBlocksTheCameraIsNotRememberedAsBlock() {
        #expect(CEFPermissionPrompts.reply(granted: false, source: .prompt) == .grant)
        #expect(CEFPermissionPrompts.reply(granted: true, source: .prompt) == .grant)
    }

    @Test func aScreenShareMacOSRefusesIsDenied() {
        #expect(CEFPermissionPrompts.reply(granted: false, source: .media) == .deny)
        #expect(CEFPermissionPrompts.reply(granted: true, source: .media) == .grant)
    }

    // MARK: The shared store

    @Test func screenSharingIsAskedEachTimeAndRemembersNothing() async {
        let store = SitePermissionStore(profile: BrowserProfileID(rawValue: UUID()), persistence: MemorySitePermissionPersistence())
        let asked = AskCount()
        for _ in 0..<2 {
            let outcome = await decide(.screen, store: store) { asked.count += 1; return .allowOnce }
            #expect(outcome == .grant)
        }
        #expect(asked.count == 2)
        #expect(store.decisions.isEmpty)
    }

    @Test func aStoredAnswerForOnlyPartOfARequestStillAsks() async {
        let store = SitePermissionStore(profile: BrowserProfileID(rawValue: UUID()), persistence: MemorySitePermissionPersistence())
        await store.whenLoaded()
        store.set(.allow, .location, for: "https://a.test")
        let asked = AskCount()
        let outcome = await decide(.capabilities([.location, .idleDetection]), store: store) { asked.count += 1; return .deny }
        #expect(asked.count == 1, "idle detection has no setting of its own")
        #expect(outcome == .deny)
        #expect(store.setting(.location, for: "https://a.test") == .allow, "a mixed answer stores nothing")
    }

    @Test func anAnswerForItemsWithSettingsIsStoredAndReused() async {
        let store = SitePermissionStore(profile: BrowserProfileID(rawValue: UUID()), persistence: MemorySitePermissionPersistence())
        let asked = AskCount()
        let first = await decide(.capabilities([.clipboard]), store: store) { asked.count += 1; return .deny }
        let second = await decide(.capabilities([.clipboard]), store: store) { asked.count += 1; return .allow }
        #expect(first == .deny)
        #expect(second == .deny)
        #expect(asked.count == 1, "the stored Block answers the second request")
    }

    @Test func closingATabRemembersNothingForTheNewQuestions() {
        for kind: BrowserPermissionKind in [.screen, .capabilities([.clipboard])] {
            #expect(BrowserPrompt(kind: .permission(kind), origin: "https://a.test") { _ in }.dismissalResponse == .cancel)
        }
    }

    private func decide(_ kind: BrowserPermissionKind, store: SitePermissionStore,
                        answer: @escaping @MainActor () -> BrowserPromptResponse) async -> SitePermissionRequest.Outcome {
        await withCheckedContinuation { continuation in
            SitePermissionRequest(kind: kind, origin: "https://a.test", store: store).decide(
                ask: { _, _, respond in respond(answer()) },
                confirm: { $0 },
                done: { continuation.resume(returning: $0) }
            )
        }
    }
}

/// How many times a request asked the person.
@MainActor
private final class AskCount {
    var count = 0
}
