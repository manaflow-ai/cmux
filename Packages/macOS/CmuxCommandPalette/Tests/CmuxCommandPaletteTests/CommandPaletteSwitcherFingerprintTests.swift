import Foundation
import Testing

@testable import CmuxCommandPalette

struct CommandPaletteSwitcherFingerprintTests {
    private func fingerprint(workspaceId: UUID, tintColorHex: String?) -> Int {
        CommandPaletteSwitcherFingerprintContext.fingerprint(windowContexts: [
            CommandPaletteSwitcherFingerprintContext(
                windowId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                windowLabel: nil,
                selectedWorkspaceId: workspaceId,
                workspaces: [
                    CommandPaletteSwitcherFingerprintWorkspace(
                        id: workspaceId,
                        displayName: "dev",
                        metadata: CommandPaletteSwitcherSearchMetadata(),
                        surfaces: [],
                        tintColorHex: tintColorHex
                    ),
                ]
            ),
        ])
    }

    @Test func aChangedRowShadeRebuildsTheSwitcher() {
        let workspaceId = UUID()
        let unshaded = fingerprint(workspaceId: workspaceId, tintColorHex: nil)
        #expect(fingerprint(workspaceId: workspaceId, tintColorHex: nil) == unshaded)
        #expect(fingerprint(workspaceId: workspaceId, tintColorHex: "#B1A2FA") != unshaded)
        #expect(fingerprint(workspaceId: workspaceId, tintColorHex: "#B1A2FA")
            != fingerprint(workspaceId: workspaceId, tintColorHex: "#E7BB4E"))
    }
}
