#if canImport(UIKit)
import GhosttyKit
import Testing

@testable import CmuxMobileTerminal

@MainActor
@Test("renderer continuation actions are consumed")
func rendererContinuationActionIsConsumed() throws {
    let surface = try #require(ghostty_surface_t(bitPattern: 1))

    #expect(
        GhosttyRuntime.simulateSurfaceActionForTesting(
            surface: surface,
            tag: GHOSTTY_ACTION_RENDER
        )
    )
}
#endif
