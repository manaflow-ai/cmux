import Darwin
import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium bounded work and cancellation")
struct ChromiumResponsivenessTests {
    @Test("A stalled CDP peer cannot grow the command queue without bound", .timeLimit(.minutes(1)))
    func boundedCommands() async throws {
        let connection = ChromiumCDPConnection(transport: ChromiumUnresponsiveTransport())
        try await connection.connect()
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<129 {
                group.addTask {
                    do { _ = try await connection.send(method: "Runtime.evaluate"); return "unexpected reply" }
                    catch { return error.localizedDescription }
                }
            }
            let first = await group.next()
            #expect(first == ChromiumBrowserDiagnostic.commandQueueFull.message)
            await connection.shutdown()
            for await _ in group {}
        }
    }

    @Test("An unresponsive command has a bounded deadline")
    func commandDeadline() async throws {
        let connection = ChromiumCDPConnection(transport: ChromiumUnresponsiveTransport(), commandTimeout: .milliseconds(20))
        try await connection.connect()
        await #expect(throws: CDPError.commandFailed(ChromiumBrowserDiagnostic.commandTimedOut.message)) {
            _ = try await connection.send(method: "Runtime.evaluate")
        }
        await connection.shutdown()
    }

    @Test("Closing private CDP releases a read even while the peer keeps its pipe open", .timeLimit(.minutes(1)))
    func cancellablePipeRead() async throws {
        var commands: [Int32] = [0, 0]
        var responses: [Int32] = [0, 0]
        #expect(pipe(&commands) == 0)
        #expect(pipe(&responses) == 0)
        defer { Darwin.close(commands[0]); Darwin.close(responses[1]) }
        let transport = try ChromiumCDPPipeTransport(commandDescriptor: commands[1], responseDescriptor: responses[0])
        await transport.connect()
        let messages = transport.messages()
        await transport.close()
        var count = 0
        for await _ in messages { count += 1 }
        #expect(count == 0)
    }

    @Test("Frame decoding rejects invalid bytes and returns a prepared bitmap")
    func imageDecode() async throws {
        let decoder = ChromiumFrameDecoder()
        #expect(await decoder.decode(Data("not an image".utf8)) == nil)
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1sAAAAASUVORK5CYII="))
        let decoded = try #require(await decoder.decode(image))
        #expect(decoded.image.width == 1)
        #expect(decoded.image.height == 1)
    }
}
