import Foundation
import GhosttyKit
@testable import CmuxTerminal

final class FakeTerminalByteTee: TerminalByteTeeBinding {
    @MainActor
    func installTee(
        on surface: ghostty_surface_t,
        owner: TerminalSurface,
        view: any TerminalSurfaceNativeViewing,
        workspaceID: UUID,
        surfaceID: UUID,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        scaleX: Double,
        scaleY: Double,
        fontSize: Float,
        context: UInt32
    ) -> any TerminalByteTeeLease {
        FakeTerminalByteTeeLease()
    }

    @MainActor
    func dropSurface(surfaceID: UUID) {}
}
