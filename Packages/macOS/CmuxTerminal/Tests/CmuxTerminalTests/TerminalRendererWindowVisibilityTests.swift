import Testing
@testable import CmuxTerminal

/// The presentation gate must never leave an on-screen window unpresented just
/// because AppKit never reported `.visible` for it (virtual/headless displays),
/// while a window whose occlusion state has proven trustworthy still releases
/// when it is miniaturized, covered, or on an inactive Space.
struct TerminalRendererWindowVisibilityTests {
    private func visible(
        occlusion: Bool = false,
        reported: Bool = false,
        onScreen: Bool = true,
        miniaturized: Bool = false,
        activeSpace: Bool = true,
        key: Bool = false
    ) -> Bool {
        TerminalRendererWindowVisibility.isVisible(
            occlusionVisible: occlusion,
            windowHasReportedVisible: reported,
            isWindowVisible: onScreen,
            isMiniaturized: miniaturized,
            isOnActiveSpace: activeSpace,
            isKeyWindow: key
        )
    }

    @Test func onScreenWindowThatNeverReportedVisiblePresents() {
        #expect(visible())
    }

    @Test func keyWindowAlwaysPresents() {
        #expect(visible(reported: true, key: true))
        #expect(visible(onScreen: false, key: true))
    }

    @Test func occlusionVerdictWinsOnceTheWindowHasReportedVisible() {
        #expect(visible(occlusion: true, reported: true))
        #expect(!visible(occlusion: false, reported: true))
    }

    @Test func untrustedOcclusionStillHonorsMiniaturizedHiddenAndInactiveSpace() {
        #expect(!visible(miniaturized: true))
        #expect(!visible(onScreen: false))
        #expect(!visible(activeSpace: false))
    }
}
