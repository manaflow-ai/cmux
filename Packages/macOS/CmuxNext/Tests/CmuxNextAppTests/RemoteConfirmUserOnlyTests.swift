@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextMacScreen
import Testing

/// `remote.confirm`'s dialog (Share This Mac, a device's access, and sharing another Mac, whose Allow
/// signs an approval with this device's key) answers only to the person. An agent can send
/// `remote.confirm`; if the debug socket's `debug.dialog` could then press Allow (or Return), the
/// agent would approve its own request and get a signed, owner-attributed approval nobody clicked.
@MainActor
struct RemoteConfirmUserOnlyTests {
    @Test func theDebugSocketCannotAnswerTheRemoteConfirmDialog() {
        #expect(CmuxRemoteActionEnvironment.confirmIdentifier == "cmux.dialog.remote.confirm")
        #expect(DebugDialog.userOnly.contains(CmuxRemoteActionEnvironment.confirmIdentifier))
        #expect(CmuxRemoteActionEnvironment.setupIdentifiers.count == 5)
        #expect(CmuxRemoteActionEnvironment.setupIdentifiers.contains("cmux.dialog.screenSharing.setup.overview"))
        #expect(CmuxRemoteActionEnvironment.setupIdentifiers.isSubset(of: DebugDialog.userOnly))
    }

    /// `debug.key {key: "return"}` reaches the blocking dialog's keyboard and presses Allow; `debug.mouse` clicks it
    /// (review follow-up on #43392, F1). While a user-only dialog shows, synthetic input is refused but a bare Escape.
    @Test func syntheticInputCannotAnswerAUserOnlyDialog() {
        func record(_ identifier: String?, visible: Bool = true) -> CmuxDialogCenter.Record {
            CmuxDialogCenter.Record(id: 1, spec: CmuxDialogSpec(title: "Share?", buttons: [CmuxDialogButton(id: "allow", title: "Allow", role: .default)],
                                                                 identifier: identifier), scope: "window", visible: visible, values: [:])
        }
        let confirm = [record(CmuxRemoteActionEnvironment.confirmIdentifier)]
        #expect(CmuxDialogKeys.syntheticInputRefusal(confirm, userOnly: DebugDialog.userOnly, onlyCancels: false) != nil)
        #expect(CmuxDialogKeys.syntheticInputRefusal(confirm, userOnly: DebugDialog.userOnly, onlyCancels: true) == nil)
        #expect(CmuxDialogKeys.syntheticInputRefusal([record("cmux.dialog.fixture")], userOnly: DebugDialog.userOnly, onlyCancels: false) == nil)
        #expect(CmuxDialogKeys.syntheticInputRefusal([record(CmuxRemoteActionEnvironment.confirmIdentifier, visible: false)], userOnly: DebugDialog.userOnly, onlyCancels: false) == nil)
        #expect(!CmuxDialogKeys.onlyCancels(key: "return", modifiers: 0, sequence: false, read: false))
        #expect(!CmuxDialogKeys.onlyCancels(key: "escape", modifiers: 1, sequence: false, read: false))
        #expect(!CmuxDialogKeys.onlyCancels(key: "escape", modifiers: 0, sequence: true, read: false))
        #expect(CmuxDialogKeys.onlyCancels(key: "escape", modifiers: 0, sequence: false, read: false))
        #expect(CmuxDialogKeys.onlyCancels(key: nil, modifiers: 0, sequence: false, read: true))
    }
}
