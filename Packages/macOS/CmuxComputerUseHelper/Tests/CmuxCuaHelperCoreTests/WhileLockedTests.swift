// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Foundation
import Testing

/// `computerUse.whileLocked` (cmuxterm-hq docs/design/locked-screen-computer-use.md): with the
/// app's answer saying so, a call to one app's window runs on a locked screen; a call that drives
/// the shared screen still gets `mac_locked`, and without the answer every call does, as before.
@Suite struct WhileLockedTests {
    /// Grants everything; `whileLocked` is what the app's answer carries.
    struct Answer: MachineConsentAuthority {
        let whileLocked: Bool
        func current() async -> MachineConsentStatus {
            MachineConsentStatus(consentRequired: false, screen: true, control: true, whileLocked: whileLocked)
        }
        func recordRefusal(surface: ConsentSurface, tool: String) async {}
    }

    static let window = ActingFootprint(tool: "type_text", arguments: Data(#"{"pid":501,"window_id":77,"text":"hi"}"#.utf8))

    func refusal(_ gate: ConsentGate, _ name: String, _ footprint: ActingFootprint) async -> ScreenLockedRefusal? {
        do {
            try await gate.admit(name, requirement: .act, footprint: footprint)
            return nil
        } catch let refusal as ScreenLockedRefusal {
            return refusal
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    @Test func aWindowCallRunsOnALockedScreenOnlyWithTheSetting() async {
        let on = ConsentGate(authority: Answer(whileLocked: true), screenLocked: { true })
        let off = ConsentGate(authority: Answer(whileLocked: false), screenLocked: { true })
        #expect(await refusal(on, "type_text", Self.window) == nil)
        #expect(await refusal(off, "type_text", Self.window) == ScreenLockedRefusal(tool: "type_text"))
    }

    @Test(arguments: [
        #"{"pid":501,"window_id":77,"text":"hi","delivery_mode":"foreground"}"#,
        #"{"scope":"desktop","x":10,"y":10}"#,
        #"{"x":10,"y":10}"#,
        #"not json"#,
    ])
    func aSharedScreenCallStaysRefusedWithTheSetting(_ arguments: String) async {
        let gate = ConsentGate(authority: Answer(whileLocked: true), screenLocked: { true })
        let footprint = ActingFootprint(tool: "click", arguments: Data(arguments.utf8))
        #expect(footprint.shared)
        let refused = await refusal(gate, "click", footprint)
        #expect(refused == ScreenLockedRefusal(tool: "click", whileLocked: true))
        #expect(refused?.description.contains("pid and window_id") == true)
    }

    @Test(arguments: ["bring_to_front", "launch_app", "invoke_menu", "clipboard_write"])
    func aToolThatChangesTheFrontmostAppStaysRefused(_ name: String) async {
        let gate = ConsentGate(authority: Answer(whileLocked: true), screenLocked: { true })
        let footprint = ActingFootprint(tool: name, arguments: Data(#"{"pid":501,"window_id":77}"#.utf8))
        #expect(await refusal(gate, name, footprint) != nil)
    }

    @Test func anInventoryReadNamesNoWindowAndStillRuns() async {
        let gate = ConsentGate(authority: Answer(whileLocked: true), screenLocked: { true })
        #expect(await refusal(gate, "list_windows", .anywhere) == nil)
        #expect(await refusal(gate, "get_desktop_state", .anywhere) != nil)
    }

    @Test func anUnlockedScreenIsUnchanged() async {
        let gate = ConsentGate(authority: Answer(whileLocked: false), screenLocked: { false })
        #expect(await refusal(gate, "click", .anywhere) == nil)
    }

    /// No trusted answer (no verified host) is the setting off.
    @Test func noAnswerIsTheSettingOff() async {
        let gate = ConsentGate(authority: UnavailableConsent(), screenLocked: { true })
        do {
            try await gate.admit("get_window_state", requirement: .observe, footprint: Self.window)
            Issue.record("ran")
        } catch {
            #expect(error is ConsentRefusal)
        }
        #expect(!MachineConsentStatus.unavailable.whileLocked)
    }

    @Test(arguments: [
        (#"{"consentRequired":false,"consent":{"screen":"none","control":"none"},"whileLocked":true}"#, true),
        (#"{"consentRequired":false,"consent":{"screen":"none","control":"none"},"whileLocked":false}"#, false),
        (#"{"consentRequired":false,"consent":{"screen":"none","control":"none"},"whileLocked":1}"#, false),
        (#"{"consentRequired":false,"consent":{"screen":"none","control":"none"},"whileLocked":"true"}"#, false),
        (#"{"consentRequired":false,"consent":{"screen":"none","control":"none"}}"#, false),
    ])
    func onlyAJSONTrueTurnsItOn(_ body: String, _ expected: Bool) throws {
        let status = try #require(MachineConsentStatus(daemonResult: Data(body.utf8)))
        #expect(status.whileLocked == expected)
    }
}
