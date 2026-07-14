#if canImport(UIKit)
import Testing
@testable import CmuxMobileTerminal

@Test("grid export and token submission are one synchronous queue operation")
func verifiedReplayExportAndTokenSubmissionStayAdjacent() {
    var events: [String] = []

    let exported = verifiedReplayExportThenSubmit(
        export: {
            events.append("export")
            return 42
        },
        submit: {
            events.append("submit")
        }
    )
    events.append("publish")

    #expect(exported == 42)
    #expect(events == ["export", "submit", "publish"])
}
#endif
