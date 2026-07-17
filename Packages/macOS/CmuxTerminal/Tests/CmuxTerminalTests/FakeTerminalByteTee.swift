import Foundation
import GhosttyKit
@testable import CmuxTerminal

final class FakeTerminalByteTee: TerminalByteTeeBinding {
    @MainActor
    func prepareTee(
        workspaceID: UUID,
        surfaceID: UUID,
        surfaceGeneration: UInt64
    ) -> TerminalByteTeeInstallation {
        TerminalByteTeeInstallation(
            callback: { _, _, _ in },
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            lease: FakeTerminalByteTeeLease()
        )
    }

    @MainActor
    func dropSurface(surfaceID: UUID) {}
}
