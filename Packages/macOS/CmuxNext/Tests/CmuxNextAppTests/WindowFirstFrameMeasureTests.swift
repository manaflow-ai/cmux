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
/// with rows and with one rows pass in it, and prints that sample: the line `WINDOW-FIRST-FRAME` of the run's log is
/// the number for the person who runs the suite, with the rows of the list beside the workspaces of the session. The
/// number is the time of the passes that ran, of the draw of the list after them (a full reload of the list) and of
/// the count of the rows. A list with rows does not show that the rows pass ran (the window's seed lists rows
/// with no rows pass), so the test asserts the sample's count of rows passes. The build of a test run has no
/// optimisation unless the run asks for one: the number is then a ceiling for the same session in a shipped app,
/// not its time.
@MainActor @Suite(.serialized) struct WindowFirstFrameMeasureTests {
    @Test(arguments: SessionFixtureSize.arms)
    func theSidebarMeasuresThePassesInFrontOfTheOrderIn(_ size: SessionFixtureSize) async throws {
        try await LargeSessionWindowFixture.withController(size) { _, controller in
            let sample = try #require(controller.sidebar.sameTurn.firstFrame, "the window's sidebar has no first-frame sample: nothing measured its order-in")
            #expect(sample.rows > 0, "the sample is of a list with no row: the window lists no workspace of the session")
            #expect(sample.rowsPasses == 1, "the sample has \(sample.rowsPasses) rows passes in its \(sample.passes) passes: its time is not that of one rows pass in front of the order-in")
            let parts = sample.duration.components
            let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
            print(String(format: "WINDOW-FIRST-FRAME %@ workspaces=%d rows=%d passes=%d ms=%.3f", size.rawValue, size.workspaces, sample.rows, sample.passes, ms))
        }
    }
}
