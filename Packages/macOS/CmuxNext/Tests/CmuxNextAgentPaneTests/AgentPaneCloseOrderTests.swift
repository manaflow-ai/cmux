import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ad349's review of the batch check: a daemon that sends its last frames and closes at once must
/// not lose them. The page gets every frame the daemon sent before its close, in order, then the
/// close. The race needs many runs to show.
@MainActor
@Suite(.serialized) struct AgentPaneCloseOrderTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#

    @Test func theDaemonsLastFramesComeBeforeItsClose() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let large = String(repeating: "x", count: 2_000_000)
        for run in 0..<200 {
            let transport = AgentPaneTransport()
            var frames: [String] = []
            var closedAfter: Int?
            transport.deliver = { event, done in
                frames += event.frames
                if event.closed != nil, closedAfter == nil { closedAfter = frames.count }
                done()
            }
            let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
            _ = await transport.send(connection: id, frames: [Self.initialize])
            for _ in 0..<2000 where !frames.contains(where: { $0.contains("protocolVersion") }) { try? await Task.sleep(for: .milliseconds(1)) }
            let last = (0..<50).map { i in
                let text = i == 25 ? large : "t"
                return #"{"jsonrpc":"2.0","method":"session/update","params":{"marker":"m-\#(run)-\#(i)","text":"\#(text)"}}"#
            }
            server.pushThenClose(last, to: server.peers.count - 1)
            for _ in 0..<5000 where closedAfter == nil { try? await Task.sleep(for: .milliseconds(1)) }
            let got = frames.compactMap { text -> Int? in
                guard let range = text.range(of: "\"m-\(run)-") else { return nil }
                return Int(text[range.upperBound...].prefix { $0.isNumber })
            }
            #expect(got == Array(0..<50), "run \(run): \(got.count) of 50 before the close")
            #expect(closedAfter != nil, "run \(run): no close")
            #expect(closedAfter == frames.count, "run \(run): frames after the close")
            if got != Array(0..<50) { break }
        }
    }
}
