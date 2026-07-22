#if DEBUG
import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellReleaseGateSupport

struct MobileIrohReleaseGateTerminalProbeTests {
    private let marker = "CMUX_IROH_GATE_0123456789ABCDEF0123456789ABCDEF"

    @Test
    func recognizesMarkerWrappedAtNarrowRenderGridBoundary() throws {
        let split = marker.index(marker.startIndex, offsetBy: 46)
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "terminal-release-gate",
            stateSeq: 1,
            columns: 46,
            rows: 2,
            full: false,
            clearedRows: [0, 1],
            rowSpans: [
                .init(row: 0, column: 0, text: String(marker[..<split])),
                .init(row: 1, column: 0, text: String(marker[split...])),
            ]
        )
        let replay = frame.vtPatchBytes()

        #expect(String(decoding: replay, as: UTF8.self).contains("\u{1B}[2;1H"))
        #expect(replay.range(of: Data(marker.utf8)) == nil)

        var probe = MobileIrohReleaseGateTerminalProbe(marker: marker)
        let chunk = MobileTerminalOutputChunk(
            data: replay,
            streamToken: UUID(),
            sourceRenderGridFrame: frame
        )
        let matched = probe.consume(chunk)

        #expect(matched)
    }

    @Test
    func submittedCommandDoesNotEchoCompleteMarker() {
        let probe = MobileIrohReleaseGateTerminalProbe(marker: marker)

        #expect(probe.command.range(of: Data(marker.utf8)) == nil)
    }
}
#endif
