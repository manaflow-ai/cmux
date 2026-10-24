import Foundation
import Testing
@testable import CmuxNextDaemon

/// D3 (plans/cmux-next/app-daemon-connection-DESIGN.md): terminal views attach as
/// client streams on the app's one daemon connection. A new view opens no
/// connection and sends no handshake; its output arrives as binary frames; a
/// view's detach ends only its own stream.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchTerminalStreamsTests {
    /// The daemon's client count (`list-clients`).
    private struct ListClients: DaemonRequest {
        typealias Response = JSONValue
        static let command = "list-clients"
    }

    private func clientCount(_ h: BranchDaemonHarness) async throws -> Int {
        switch try await h.connection.request(ListClients()) {
        case .array(let clients): return clients.count
        case .object(let fields):
            if case .array(let clients)? = fields["clients"] { return clients.count }
            return 0
        default: return 0
        }
    }

    /// Output of `view` until `text` shows, or the stream ends.
    private func output(of view: TerminalAttachment, until text: String) async -> (String, TerminalChannelCloseReason?) {
        var output = ""
        for await event in view.events {
            switch event {
            case .output(let data, _): output += String(decoding: data, as: UTF8.self)
            case .closed(let reason): return (output, reason)
            default: break
            }
            if output.contains(text) { return (output, nil) }
        }
        return (output, nil)
    }

    @Test func twoViewsShareTheAppConnectionWithNoHandshakeAndEndOnlyTheirOwnStream() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, _, first) = try await h.workspaceWithTerminal("streams-a")
            let (_, _, second) = try await h.workspaceWithTerminal("streams-b")
            let device = TerminalSizingDevice(kind: "mac", name: "streams-test")
            let carrier = try #require(try await h.connection.terminalStreams(device: device),
                                       "the branch daemon serves attach-streams-v1")
            #expect(carrier.frames, "a local connection negotiates binary frames")
            let clientsBefore = try await clientCount(h)
            let views = try await [first, second].asyncMap { surface in
                try await TerminalAttachment.attach(
                    carrier: carrier, target: .init(surface: surface, generation: h.identity.generation),
                    size: CellSize(cols: 80, rows: 24), claimGeometry: true)
            }
            // No connection per view: the daemon still counts the same clients.
            #expect(try await clientCount(h) == clientsBefore)
            #expect(views[0].stream != views[1].stream)
            #expect(views.allSatisfy { $0.stream != nil })

            views[0].enqueueInput(Data("echo first-$((40+2))\r".utf8))
            views[1].enqueueInput(Data("echo second-$((40+3))\r".utf8))
            let (firstOutput, firstEnd) = await output(of: views[0], until: "first-42")
            let (secondOutput, secondEnd) = await output(of: views[1], until: "second-43")
            #expect(firstOutput.contains("first-42") && firstEnd == nil, "\(firstOutput.debugDescription)")
            #expect(secondOutput.contains("second-43") && secondEnd == nil, "\(secondOutput.debugDescription)")
            #expect(!firstOutput.contains("second-43"), "a view got another view's output")

            // Detaching one view ends its stream only.
            views[0].detachNow()
            var ended: TerminalChannelCloseReason?
            for await event in views[0].events { if case .closed(let reason) = event { ended = reason } }
            #expect(ended == .detachedByClient)
            views[1].enqueueInput(Data("echo still-$((40+4))\r".utf8))
            let (after, afterEnd) = await output(of: views[1], until: "still-44")
            #expect(after.contains("still-44") && afterEnd == nil, "the other view stopped: \(after.debugDescription)")
            #expect(carrier.transport.strayStreamMessages == 0)
            views[1].detachNow()
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
