import Foundation
import Testing
@testable import CmuxVNC
@testable import CmuxVNCDemoServer

/// The demo desktop's animation clock runs only while a viewer is connected: a started server with
/// no viewer wakes nobody (p14-energy-067f).
struct DemoServerClockTests {
    @Test func theClockWaitsForAViewer() async throws {
        let server = VNCDemoServer(configuration: .init(width: 64, height: 64, framesPerSecond: 30))
        let port = try await server.start()
        defer { server.stop() }
        #expect(await server.animationClockRuns() == false, "no viewer: no animation frames")
        let client = VNCClient(endpoint: VNCEndpoint(host: "127.0.0.1", port: port), options: VNCSessionOptions())
        await client.connect()
        var events = client.events.makeAsyncIterator()
        guard case .connected? = await events.next() else {
            Issue.record("did not connect")
            return
        }
        #expect(await server.animationClockRuns(), "a viewer is connected: the clock runs")
        await client.disconnect()
    }
}
