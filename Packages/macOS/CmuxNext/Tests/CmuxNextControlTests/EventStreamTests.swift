@testable import CmuxNextControl
import CmuxNextSettings
import Darwin
import Foundation
import Testing

/// `events.stream` over the socket, as the `cmux events` CLI and the iOS
/// dogfood launcher use it: ack with the resume cursor, replay after it,
/// name filters, then live events.
@Suite(.serialized) struct EventStreamTests {
    @Test func snapshotCursorThenFilteredReplayAndLiveEvents() throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .allowAll), router: router)
        try server.start()
        defer { server.stop() }
        router.events.publish(name: "other.thing", category: "misc", source: "test", payload: [:])

        // `--snapshot`: the ack carries latest_seq, the launcher's cursor.
        let snapshot = try LineClient(path: server.configuration.path)
        let ack = try JSONValue.parse(Data(snapshot.send(#"{"id":"1","method":"events.stream","params":{"include_heartbeats":false}}"#).utf8))
        #expect(ack["type"] == "ack")
        #expect(ack["resume"]?["latest_seq"] == 1)
        let cursor = try #require(ack["resume"]?["latest_seq"]?.intValue)

        router.events.publish(name: "mobile.rpc.ready", category: "mobile", source: "mobile.host",
                              payload: ["client_id": "c1", "workspace_count": 2])
        router.events.publish(name: "other.thing", category: "misc", source: "test", payload: [:])

        // `--after <cursor> --name mobile.rpc.ready`: replay only the match.
        let waiter = try LineClient(path: server.configuration.path)
        let request = #"{"id":"2","method":"events.stream","params":{"after_seq":\#(cursor),"names":["mobile.rpc.ready"],"include_heartbeats":false}}"#
        let ack2 = try JSONValue.parse(Data(waiter.send(request).utf8))
        #expect(ack2["replay_count"] == 1)
        let event = try JSONValue.parse(Data(waiter.readLine().utf8))
        #expect(event["type"] == "event")
        #expect(event["name"] == "mobile.rpc.ready")
        #expect(event["seq"] == 2)
        #expect(event["payload"]?["client_id"] == "c1")

        // Live: a later matching event arrives on the open stream.
        router.events.publish(name: "mobile.rpc.ready", category: "mobile", source: "mobile.host", payload: ["client_id": "c2"])
        let live = try JSONValue.parse(Data(waiter.readLine().utf8))
        #expect(live["seq"] == 4)
        #expect(live["payload"]?["client_id"] == "c2")
    }

    @Test func busIsBounded() {
        let bus = ControlEventBus(retainLimit: 3)
        for index in 0..<5 { bus.publish(name: "n", category: "c", source: "s", payload: ["i": JSONValue(index)]) }
        let subscription = bus.subscribe(after: 0, names: [], categories: [])
        #expect(subscription.replay.count == 3)
        #expect(subscription.ack["resume"]?["gap"] == true)
        subscription.cancel()
    }
}
