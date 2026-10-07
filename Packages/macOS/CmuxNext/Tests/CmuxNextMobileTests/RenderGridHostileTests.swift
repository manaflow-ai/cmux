import Foundation
import Testing
@testable import CmuxNextMobile

/// Render events from the daemon are external data: bad sizes and widths
/// must be refused or clamped, never trap.
struct RenderGridHostileTests {
    private func frame(_ json: String) throws -> DaemonRenderFrame {
        try JSONDecoder().decode(DaemonRenderFrame.self, from: Data(json.utf8))
    }

    private let cursor = #""cursor":{"x":0,"y":0,"style":"block","blink":false,"visible":true}"#

    @Test func aGrowingDeltaPatchesRowsPastTheOldSize() throws {
        var state = DaemonRenderGridState(surfaceID: "S")
        #expect(state.apply(try frame(#"{"event":"render-state","size":{"cols":10,"rows":2},"# + cursor + #","rows":[]}"#)))
        let grow = #"{"event":"render-delta","full":false,"size":{"cols":10,"rows":5},"# + cursor
            + #","rows":[{"row":4,"runs":[{"text":"hi","attrs":0}]}]}"#
        #expect(state.apply(try frame(grow)))
        #expect(try state.frame(stateSeq: 1).rows == 5)
    }

    @Test func hugeAndNegativeWidthHintsDoNotOverflow() throws {
        var state = DaemonRenderGridState(surfaceID: "S")
        let json = #"{"event":"render-state","size":{"cols":10,"rows":1},"# + cursor
            + #","rows":[{"row":0,"runs":[{"text":"a","attrs":0,"width_hint":9223372036854775807},{"text":"b","attrs":0,"width_hint":9223372036854775807},{"text":"c","attrs":0,"width_hint":-9223372036854775808},{"text":"d","attrs":0,"width_hint":-9223372036854775808}]}]}"#
        #expect(state.apply(try frame(json)))
        _ = try state.frame(stateSeq: 1)
    }

    @Test func anAbsurdViewportIsClamped() throws {
        var state = DaemonRenderGridState(surfaceID: "S")
        let json = #"{"event":"render-state","size":{"cols":2000000000,"rows":2000000000},"# + cursor + #","rows":[]}"#
        #expect(state.apply(try frame(json)))
        #expect(state.hasViewport)
    }
}
