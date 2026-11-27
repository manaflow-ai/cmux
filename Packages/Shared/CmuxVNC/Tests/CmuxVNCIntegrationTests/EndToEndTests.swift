import CmuxVNCDemoServer
import Foundation
import Testing
@testable import CmuxVNC

/// The client against the loopback demo server: real TCP, real zlib.
struct EndToEndTests {
    func firstFrame(_ client: VNCClient) async -> VNCFrame? {
        for await frame in client.frames { return frame }
        return nil
    }

    @Test(arguments: [true, false])
    func connectsAndStreams(zrle: Bool) async throws {
        let server = VNCDemoServer(configuration: .init(width: 320, height: 200, password: "hunter2", framesPerSecond: 30))
        let port = try await server.start()
        defer { server.stop() }
        let encodings: [RFBEncoding]? = zrle ? nil : [.raw]
        let client = VNCClient(endpoint: VNCEndpoint(host: "127.0.0.1", port: port),
                               options: VNCSessionOptions(credentials: VNCCredentials(password: "hunter2"), encodings: encodings))
        await client.connect()
        var events = client.events.makeAsyncIterator()
        guard case let .connected(info)? = await events.next() else {
            Issue.record("did not connect")
            return
        }
        #expect(info.width == 320 && info.height == 200 && info.securityType == 2)
        let frame = try #require(await firstFrame(client))
        #expect(frame.width == 320 && frame.height == 200)
        #expect(frame.makeImage() != nil)
        // The animation keeps frames coming.
        var count = 0
        for await _ in client.frames {
            count += 1
            if count == 5 { break }
        }
        #expect(count == 5)
        let stats = await client.stats
        let encoding = zrle ? RFBEncoding.zrle.rawValue : RFBEncoding.raw.rawValue
        #expect((stats.rectanglesByEncoding[encoding] ?? 0) > 0)
        await client.disconnect()
    }

    @Test func wrongPasswordFails() async throws {
        let server = VNCDemoServer(configuration: .init(width: 64, height: 64, password: "right"))
        let port = try await server.start()
        defer { server.stop() }
        let client = VNCClient(endpoint: VNCEndpoint(host: "127.0.0.1", port: port),
                               options: VNCSessionOptions(credentials: VNCCredentials(password: "wrong")))
        await client.connect()
        var last: VNCEvent?
        for await event in client.events { last = event }
        guard case let .disconnected(error?)? = last else {
            Issue.record("expected a failure, got \(String(describing: last))")
            return
        }
        #expect(error.needsCredentials)
    }

    @Test func typingReachesTheServerAndCursorArrives() async throws {
        let server = VNCDemoServer(configuration: .init(width: 200, height: 120, framesPerSecond: 0))
        let port = try await server.start()
        defer { server.stop() }
        let client = VNCClient(endpoint: VNCEndpoint(host: "127.0.0.1", port: port), options: VNCSessionOptions(localCursor: true))
        await client.connect()
        var sawCursor = false
        for await event in client.events {
            if case .connected = event {
                await client.type("hi")
                await client.key(.shift, down: true)
                await client.key(VNCKeysym(character: "a"), down: true)
                await client.key(VNCKeysym(character: "a"), down: false)
                await client.key(.shift, down: false)
            }
            if case .cursor = event {
                sawCursor = true
                break
            }
        }
        #expect(sawCursor)
        // Input is ordered on one stream; a frame after it reflects it.
        _ = await firstFrame(client)
        var typed = ""
        for _ in 0 ..< 50 {
            typed = await server.typedText()
            if typed == "hiA" { break }
            _ = await firstFrame(client)
        }
        #expect(typed == "hiA")
        await client.disconnect()
    }
}
