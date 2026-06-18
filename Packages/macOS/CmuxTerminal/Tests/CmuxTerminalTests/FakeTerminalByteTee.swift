import Foundation
import GhosttyKit
@testable import CmuxTerminal

final class FakeTerminalByteTee: TerminalByteTeeBinding {
    @MainActor
    func installTee(on surface: ghostty_surface_t, surfaceID: UUID) -> any TerminalByteTeeLease {
        FakeTerminalByteTeeLease()
    }

    @MainActor
    func dropSurface(surfaceID: UUID) {}
}
