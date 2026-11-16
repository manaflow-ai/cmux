import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// The sidebar's own measure of the passes that run in front of a window's order-in
/// (`SidebarSameTurn.completeFirstFrame`), on a whole window of a session of a ``SessionFixtureSize`` (`large` by
/// default: 60 workspaces x 6 tabs).
///
/// The test reads no clock and asserts no time. It asserts that the window's sidebar has a sample of its order-in
/// with rows and at least one pass, and prints that sample: the line `WINDOW-FIRST-FRAME` of the run's log is the
/// number for the person who runs the suite, with the rows of the list beside the workspaces of the session. The
/// build of a test run has no optimisation: the number is a ceiling for the same session in a shipped app, not its
/// time.
@MainActor @Suite(.serialized) struct WindowFirstFrameMeasureTests {
    @Test(arguments: SessionFixtureSize.arms)
    func theSidebarMeasuresThePassesInFrontOfTheOrderIn(_ size: SessionFixtureSize) async throws {
        try await LargeSessionWindowFixture.withController(size) { _, controller in
            let sample = try #require(controller.sidebar.sameTurn.firstFrame, "the window's sidebar has no first-frame sample: nothing measured its order-in")
            #expect(sample.rows > 0, "the sample is of a list with no row: the rows pass did not run in front of the order-in")
            #expect(sample.passes >= 1, "no pass ran in front of the order-in: the sample has no rows pass in it")
            let parts = sample.duration.components
            let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
            print(String(format: "WINDOW-FIRST-FRAME %@ workspaces=%d rows=%d passes=%d ms=%.3f", size.rawValue, size.workspaces, sample.rows, sample.passes, ms))
        }
    }
}
