#if canImport(UIKit)
import Foundation
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

@Test("grid export and token submission can run on the surface work queue")
func verifiedReplayExportAndTokenSubmissionRunOffMainThread() async {
    let result = await withCheckedContinuation { continuation in
        DispatchQueue(label: "dev.cmux.tests.verified-replay.surface").async {
            var events: [String] = []
            let ranOnMainThread = Thread.isMainThread
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
            continuation.resume(returning: (exported, events, ranOnMainThread))
        }
    }

    #expect(result.0 == 42)
    #expect(result.1 == ["export", "submit", "publish"])
    #expect(!result.2)
}
#endif
