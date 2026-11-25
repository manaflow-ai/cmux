import CmuxNextAgentPane
import Foundation
import Testing

struct AgentPaneExternalAccessTests {
    @Test func decodesOnlyKnownSettingsKinds() {
        #expect(AgentPaneRequest(body: ["method": "externalAccess.openSettings", "params": ["kind": "files_and_folders"]]) == .externalAccessOpenSettings(.filesAndFolders))
        #expect(AgentPaneRequest(body: ["method": "externalAccess.openSettings", "params": ["kind": "full_disk_access"]]) == .externalAccessOpenSettings(.fullDiskAccess))
        #expect(AgentPaneRequest(body: ["method": "externalAccess.openSettings", "params": ["kind": "screen_recording"]]).description == "unsupported")
        #expect(AgentPaneRequest(body: ["method": "externalAccess.openSettings", "params": ["kind": "files_and_folders", "extra": true]]).description == "unsupported")
    }

    @Test func settingsAnchorIsClosedAndDoesNotIncludeThePath() {
        #expect(AgentPaneExternalAccessKind.filesAndFolders.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        #expect(AgentPaneExternalAccessKind.fullDiskAccess.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    @Test @MainActor func remoteBlocksNeverOpenLocalSettingsAndMissingGestureDoesNotOpen() {
        let gestures = AgentPaneUserGestures(now: { 100 })
        var opened: URL?
        #expect(AgentPaneExternalAccess().open(.filesAndFolders, remoteChat: true, gestures: gestures, open: { opened = $0 })["ok"] as? Bool == false)
        #expect(opened == nil)
        #expect(AgentPaneExternalAccess().open(.filesAndFolders, remoteChat: false, gestures: gestures, open: { opened = $0 })["ok"] as? Bool == false)
        #expect(opened == nil)
    }

    @Test @MainActor func aFreshGestureOpensExactlyTheSelectedDestinationOnce() {
        let gestures = AgentPaneUserGestures(now: { 100 })
        gestures.record()
        var opened: URL?
        #expect(AgentPaneExternalAccess().open(.fullDiskAccess, remoteChat: false, gestures: gestures, open: { opened = $0 })["ok"] as? Bool == true)
        #expect(opened?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        opened = nil
        #expect(AgentPaneExternalAccess().open(.fullDiskAccess, remoteChat: false, gestures: gestures, open: { opened = $0 })["ok"] as? Bool == false)
        #expect(opened == nil)
    }
}
