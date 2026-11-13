import Foundation
@testable import CmuxNextRemoteView
import Testing

/// Why an rd session ended reaches its status (`endReason`, read by `cmux app remote-views`): the
/// carrier's close reason, nil while the session is live.
@Suite struct RemoteRdSessionEndReasonTests {
    private nonisolated final class RecordedCarrier: RemoteRdByteCarrier {
        let packets: [Data]
        init(_ messages: [RemoteRdControl]) throws {
            packets = try messages.map { try RemoteRdCore.streamFrame($0.json(), control: true) }
        }
        func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
            events(.ready)
            for packet in packets { events(.data(packet)) }
            events(.closed(reason: "recording ended"))
        }
        func send(_ bytes: Data) {}
        func cancel() {}
    }

    @Test(arguments: ["rd_wg", "link", "future_carrier"])
    func selectedCarrierComesFromAcceptedWelcomeAndEndsWithSession(_ carrierName: String) async throws {
        let welcome = RemoteRdWelcome(encoder: "h264", width: 100, height: 100,
                                      maxDatagram: 1126, carrier: carrierName, service: "desktop")
        let carrier = try RecordedCarrier([.welcome(welcome), .started(session: 1), .ended(reason: "done")])
        let transport = try #require(RemoteRdStreamTransport(carrier: carrier,
            hello: .cloudDesktop(install: "test"), startKey: "k"))
        let statuses = transport.statusUpdates()
        transport.connect()
        var seen: [RemoteViewStatus] = []
        for await status in statuses { seen.append(status) }
        #expect(seen.first?.carrier == nil)
        #expect(seen.first(where: { $0.state == .streaming })?.carrier == carrierName)
        #expect(seen.last?.carrier == nil)
    }

    @Test func mismatchedServiceCannotAttestACarrier() async throws {
        let welcome = RemoteRdWelcome(encoder: "h264", width: 100, height: 100,
                                      maxDatagram: 1126, carrier: "rd_wg", service: "other")
        let carrier = try RecordedCarrier([.welcome(welcome), .started(session: 1)])
        let transport = try #require(RemoteRdStreamTransport(carrier: carrier,
            hello: .cloudDesktop(install: "test"), startKey: "k"))
        let statuses = transport.statusUpdates()
        transport.connect()
        for await status in statuses {
            #expect(status.carrier == nil)
            #expect(status.state != .streaming)
        }
    }

    private struct NoLink: Error, CustomStringConvertible {
        var description: String { "no link to the machine" }
    }

    @Test func aStreamThatDoesNotOpenEndsWithTheOpensError() async throws {
        let carrier = RemoteRdStreamCarrier(open: { throw NoLink() })
        let transport = try #require(RemoteRdStreamTransport(carrier: carrier, hello: RemoteRdHello.cloudDesktop(install: "test"),
                                                             startKey: "k"))
        var seen: [RemoteViewStatus] = []
        let statuses = transport.statusUpdates()
        transport.connect()
        // The transport finishes the stream once the session ends.
        for await status in statuses {
            seen.append(status)
        }
        let live = try #require(seen.first)
        #expect(live.state == .connecting)
        #expect(live.endReason == nil)
        let ended = try #require(seen.last)
        #expect(ended.state == .ended(.connectionLost), "the pane's state and behavior are unchanged")
        #expect(ended.endReason == "rd stream did not open: no link to the machine")
    }

    /// Reconnect starts a new session: the pane drops the old session's reason at once instead of
    /// showing it until the new transport's first status arrives.
    @Test func reconnectDropsTheEndedSessionsReason() {
        var state = RemotePaneState(hostName: "vm", requestedMode: .view)
        state.status = RemoteViewStatus(state: .ended(.connectionLost), endReason: "rd stream did not open: no link to the machine")
        let reconnected = RemotePaneReducer().reduce(state, .reconnect)
        #expect(reconnected.sessionState == .connecting)
        #expect(reconnected.status?.endReason == nil)
    }
}
