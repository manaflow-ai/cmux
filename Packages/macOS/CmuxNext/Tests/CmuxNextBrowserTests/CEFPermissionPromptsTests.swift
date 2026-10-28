import Foundation
import Testing
@testable import CmuxNextBrowser

/// Every Chromium permission request is asked from data. Chromium's permission
/// bubble is a Views widget a host-mode page never shows, so a request cmux does not ask about
/// waits until the page goes away. With the default-off feature `chromiumPermissionPromptsFromData`
/// the shim sends every `cef_permission_request_types_t` as PERMISSION_PROMPT
/// (CEFShim/src/permission_prompt_policy.h, its cases in
/// scripts/cmux-next/test-shim-permission-prompts-cpp.sh); these cases cover what cmux asks and
/// answers, and when it asks macOS for a capture.
@MainActor
@Suite struct CEFPermissionPromptsTests {
    private static let camera: Int64 = 1 << 2
    private static let microphone: Int64 = 1 << 12

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

    @Test func thePromptEventCarriesItsBits() {
        let event = CEFShimEvent(kind: 41, browser: 3, request: 8, a: Self.camera, b: 0, s1: "https://a.test", s2: "")
        guard case .permissionPrompt(_, let token, let permissions, let origin) = event else {
            Issue.record("not a permission prompt: \(event)")
            return
        }
        #expect(token == 8)
        #expect(origin == "https://a.test")
        #expect(CEFPermissionRequest(permissions: permissions).kind == .capabilities([.camera]))
    }

    // MARK: macOS access

    @Test func capturesNeedMacOSAccess() {
        #expect(CEFCapture.needed(by: .capabilities([.camera, .microphone])) == [.camera, .microphone])
        #expect(CEFCapture.needed(by: .capabilities([.cameraPanTiltZoom])) == [.camera])
        #expect(CEFCapture.needed(by: .capabilities([.clipboard, .location])).isEmpty)
        #expect(CEFCapture.needed(by: .location).isEmpty)
    }

    @Test func anAllowedCaptureAsksMacOSOnceBeforeChromiumHears() async {
        let access = RecordingCaptureAccess()
        let outcome = await CEFPermissionPrompts.confirm(.grant, kind: .capabilities([.camera, .microphone]), capture: access)
        #expect(outcome == .grant)
        #expect(access.calls == [[.camera, .microphone]])
    }

    @Test func blockAndDismissNeverAskMacOS() async {
        let access = RecordingCaptureAccess()
        for answer: SitePermissionRequest.Outcome in [.deny, .dismiss] {
            let outcome = await CEFPermissionPrompts.confirm(answer, kind: .capabilities([.camera, .microphone]), capture: access)
            #expect(outcome == answer)
        }
        #expect(access.calls.isEmpty)
    }

    @Test func aKindWithNoCapturePassesTheOutcomeThrough() async {
        let access = RecordingCaptureAccess()
        for kind: BrowserPermissionKind in [.location, .capabilities([.clipboard, .midiSysex])] {
            #expect(await CEFPermissionPrompts.confirm(.grant, kind: kind, capture: access) == .grant)
        }
        #expect(access.calls.isEmpty)
    }

    @Test func thePromptsAnswerReachesChromiumOnlyAfterMacOSWasAsked() async {
        // The whole decision as CEFPermissionPrompts runs it: the person's Allow, then macOS, then `done`.
        let store = SitePermissionStore(profile: BrowserProfileID(rawValue: UUID()), persistence: MemorySitePermissionPersistence())
        let access = RecordingCaptureAccess()
        let kind = BrowserPermissionKind.capabilities([.camera])
        let outcome: SitePermissionRequest.Outcome = await withCheckedContinuation { continuation in
            SitePermissionRequest(kind: kind, origin: "https://a.test", store: store).decide(
                ask: { _, _, respond in respond(.allowOnce) },
                confirm: { await CEFPermissionPrompts.confirm($0, kind: kind, capture: access) },
                done: { outcome in
                    access.log.append("done")
                    continuation.resume(returning: outcome)
                }
            )
        }
        #expect(outcome == .grant)
        #expect(access.log == ["authorize", "done"])
    }

    // MARK: The shared store

    @Test func aRequestWithNoSettingIsAskedEachTimeAndRemembersNothing() async {
        let store = SitePermissionStore(profile: BrowserProfileID(rawValue: UUID()), persistence: MemorySitePermissionPersistence())
        let asked = AskCount()
        for _ in 0..<2 {
            let outcome = await decide(.capabilities([.idleDetection]), store: store) { asked.count += 1; return .allow }
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
        for kind: BrowserPermissionKind in [.capabilities([.clipboard]), .capabilities([.idleDetection])] {
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

/// A `CEFCaptureAccess` that records what macOS was asked, and when.
@MainActor
private final class RecordingCaptureAccess: CEFCaptureAccess {
    var calls: [[CEFCapture]] = []
    var log: [String] = []

    func authorize(_ captures: [CEFCapture]) async {
        calls.append(captures)
        log.append("authorize")
    }
}
