import Foundation
import GhosttyKit
@testable import CmuxTerminal

final class FakeTerminalByteTee: TerminalByteTeeBinding {
    @MainActor
    func installTee(
        on surface: ghostty_surface_t,
        workspaceID: UUID,
        surfaceID: UUID,
        surfaceGeneration: UInt64
    ) -> any TerminalByteTeeLease {
        FakeTerminalByteTeeLease()
    }

    @MainActor
    func dropSurface(surfaceID: UUID, surfaceGeneration: UInt64) {}
}
