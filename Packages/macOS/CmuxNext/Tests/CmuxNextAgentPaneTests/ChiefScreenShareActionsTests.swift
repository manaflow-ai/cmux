import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDictation
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A screen that is allowed (or not) and never changes after its first frame.
private struct StillScreen: ChiefScreenCapturing {
    var allowed = true

    @concurrent func isAllowed() async -> Bool { allowed }
    @concurrent func requestAccess() async -> Bool { allowed }
    @concurrent func capture(changedSince previous: VoiceRoomFrameSignature?) async throws -> ChiefScreenFrame? {
        guard previous == nil, let signature = VoiceRoomFrameSignature(pixels: [UInt8](repeating: 9, count: 640)) else { return nil }
        return ChiefScreenFrame(signature: signature, jpeg: Data(), text: "Terminal — cargo test: 15 passed", app: "cmux", window: nil)
    }
}

/// A journal that answers every record while sharing.
private actor EchoJournal: ChiefScreenJournaling {
    private var sharing = false
    func beginSharing() { sharing = true }
    func endSharing() { sharing = false }
    func record(_ frame: ChiefScreenFrame, at: Date, remember: Bool) -> ChiefScreenObservation? {
        guard sharing else { return nil }
        return ChiefScreenObservation(at: at, day: "2026-10-30", time: "17:42:05", app: frame.app, window: frame.window,
                                      text: frame.text, frame: "/h/optchat/screen/frames/2026-10-30/174205-000.jpg")
    }
}

/// Every entrypoint (header toggle, palette, CLI, MCP) runs these actions, so they are the
/// behavior: toggle starts and stops, stop and look are unavailable while off, look answers the
/// frame, the indicator follows the state, and a refused permission says why and opens Settings.
@MainActor
@Suite(.serialized) struct ChiefScreenShareActionsTests {
    private static func make(allowed: Bool = true) -> (ChiefScreenShare, ActionRegistry, ChiefScreenShareIndicator, () -> Int) {
        let share = ChiefScreenShare(capture: StillScreen(allowed: allowed), journal: EchoJournal(), clock: ManualClock())
        let registry = ActionRegistry(catalog: ActionCatalog.all)
        let indicator = ChiefScreenShareIndicator(showsInMenuBar: false)
        var opened = 0
        ChiefScreenShareActions(share: share, registry: registry, indicator: indicator, openPermissionSettings: { opened += 1 }).bind()
        return (share, registry, indicator, { opened })
    }

    @Test func theToggleStartsAndStopsSharingAndTheIndicatorFollows() async throws {
        let (share, registry, indicator, _) = Self.make()
        #expect(registry.unavailableReason(for: ChiefScreenShareActions.stopID) != nil)
        #expect(registry.unavailableReason(for: ChiefScreenShareActions.lookID) != nil)
        #expect(registry.perform(ChiefScreenShareActions.toggleID, invocation: ActionInvocation(origin: .user)))
        #expect(share.isOn, "the click shows sharing at once")
        await share.settled()
        #expect(share.state == .sharing)
        try await until { indicator.isVisible }
        #expect(registry.unavailableReason(for: ChiefScreenShareActions.stopID) == nil)
        #expect(registry.perform(ChiefScreenShareActions.toggleID, invocation: ActionInvocation(origin: .user)))
        #expect(share.state == .off)
        try await until { !indicator.isVisible }
    }

    @Test func lookAnswersTheFrameFileAndText() async throws {
        let (share, registry, _, _) = Self.make()
        #expect(registry.perform(ChiefScreenShareActions.startID, invocation: ActionInvocation(origin: .user)))
        await share.settled()
        let run = registry.capturingRun { _ = registry.perform(ChiefScreenShareActions.lookID, invocation: ActionInvocation(origin: .user)) }
        let result = try #require(run.results.first)
        let fields = try await result.value.get()
        #expect(fields["frame"] == .string("/h/optchat/screen/frames/2026-10-30/174205-000.jpg"))
        #expect(fields["text"] == .string("Terminal — cargo test: 15 passed"))
        #expect(registry.perform(ChiefScreenShareActions.stopID, invocation: ActionInvocation(origin: .user)))
        #expect(registry.unavailableReason(for: ChiefScreenShareActions.lookID) != nil)
    }

    @Test func aRefusedPermissionSaysWhyAndOpensSettings() async throws {
        let (share, registry, indicator, opened) = Self.make(allowed: false)
        var refusals: [String] = []
        registry.refusalObserver = { reason, _ in refusals.append(reason) }
        #expect(registry.perform(ChiefScreenShareActions.startID, invocation: ActionInvocation(origin: .user)))
        await share.settled()
        #expect(share.state == .needsPermission)
        try await until { opened() == 1 }
        #expect(refusals.count == 1)
        #expect(!indicator.isVisible)
    }

    /// Only the person starts capture: start and toggle are person-only (the control socket, so the
    /// CLI from any terminal agent, is refused) and no MCP tool; stop and look are offered.
    @Test func onlyThePersonStartsAndAgentsMayStopAndLook() throws {
        let plan = { (id: ActionID) in ActionCatalog.all.first { $0.id == id }?.surfacePlan }
        for id in [ChiefScreenShareActions.startID, ChiefScreenShareActions.toggleID] {
            #expect(try #require(plan(id)).mcp?.isOffered == false, "\(id) must not be an MCP tool")
            #expect(try #require(plan(id)).cli?.isOffered == true)
            #expect(ActionCatalog.all.first { $0.id == id }?.isPersonOnly == true)
        }
        for id in [ChiefScreenShareActions.stopID, ChiefScreenShareActions.lookID] {
            #expect(try #require(plan(id)).mcp?.isOffered == true)
            #expect(ActionCatalog.all.first { $0.id == id }?.isPersonOnly == false)
        }
    }

    /// Waits for an Observation-driven change: yields to the main actor until `condition` holds.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        #expect(condition())
    }
}
