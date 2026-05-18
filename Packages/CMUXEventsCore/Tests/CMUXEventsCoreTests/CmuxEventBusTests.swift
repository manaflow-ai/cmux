import XCTest
@testable import CMUXEventsCore

final class CmuxEventBusTests: XCTestCase {
    func testStreamRequestParsesFiltersCursorAndHeartbeatOption() throws {
        let line = """
        {"method":"events.stream","params":{"after_seq":"42","names":[" workspace.created ",""],"category":"notification","include_heartbeat":"false"}}
        """

        let request = try CmuxEventStreamRequest(line: line)

        XCTAssertTrue(CmuxEventStreamRequest.isStreamRequest(line))
        XCTAssertEqual(request.afterSequence, 42)
        XCTAssertEqual(request.names, ["workspace.created"])
        XCTAssertEqual(request.categories, ["notification"])
        XCTAssertEqual(request.includeHeartbeats, false)
    }

    func testStreamRequestSupportsAliasesAndDefaults() throws {
        let line = """
        {"method":"events.stream","params":{"after":7,"name":"surface.created","categories":["surface","pane"]}}
        """

        let request = try CmuxEventStreamRequest(line: line)

        XCTAssertEqual(request.afterSequence, 7)
        XCTAssertEqual(request.names, ["surface.created"])
        XCTAssertEqual(request.categories, ["surface", "pane"])
        XCTAssertEqual(request.includeHeartbeats, true)
    }

    func testStreamRequestRejectsInvalidPayloads() {
        XCTAssertFalse(CmuxEventStreamRequest.isStreamRequest("events.stream"))
        XCTAssertThrowsError(try CmuxEventStreamRequest(line: "events.stream")) { error in
            XCTAssertEqual(error as? CmuxEventStreamRequestParseError, .invalidRequest)
        }
        XCTAssertThrowsError(try CmuxEventStreamRequest(line: #"{"method":"surface.focus"}"#)) { error in
            XCTAssertEqual(error as? CmuxEventStreamRequestParseError, .invalidRequest)
        }
    }

    func testSubscribeReplaysEventsAfterSequenceAndReportsAck() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        bus.publish(
            name: "workspace.created",
            category: "workspace",
            source: "test",
            workspaceId: "w1",
            payload: ["value": "one"]
        )
        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "w1",
            payload: ["title": "Done"]
        )

        let snapshot = bus.subscribe(afterSequence: 1, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        XCTAssertEqual(snapshot.replay.count, 1)
        XCTAssertEqual(snapshot.replay.first?["name"] as? String, "notification.created")
        XCTAssertEqual(snapshot.ack["type"] as? String, "ack")
        XCTAssertEqual(snapshot.ack["replay_count"] as? Int, 1)

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual((resume["latest_seq"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(resume["gap"] as? Bool, false)
    }

    func testSubscribeReportsGapWhenCursorFallsOutOfRetention() throws {
        let bus = CmuxEventBus(retainedEventLimit: 2)
        bus.publish(name: "a", category: "test", source: "test")
        bus.publish(name: "b", category: "test", source: "test")
        bus.publish(name: "c", category: "test", source: "test")

        let snapshot = bus.subscribe(afterSequence: 0, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual(resume["gap"] as? Bool, true)
        XCTAssertEqual(snapshot.replay.compactMap { $0["name"] as? String }, ["b", "c"])
    }

    func testSubscribeReportsGapWhenCursorIsNewerThanProcess() throws {
        let bus = CmuxEventBus(retainedEventLimit: 2)
        let snapshot = bus.subscribe(afterSequence: 42, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual(resume["gap"] as? Bool, true)
        XCTAssertEqual((resume["latest_seq"] as? NSNumber)?.int64Value, 0)
        XCTAssertNotNil(snapshot.ack["boot_id"] as? String)
    }

    func testSubscriptionFiltersLiveEventsByCategory() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let snapshot = bus.subscribe(afterSequence: nil, names: [], categories: ["notification"])
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(name: "workspace.created", category: "workspace", source: "test")
        bus.publish(name: "notification.created", category: "notification", source: "test")

        let event = snapshot.subscription.next(timeout: 0.2)
        XCTAssertEqual(event?["name"] as? String, "notification.created")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testSubscriptionNextIgnoresStaleWakeupsAfterImmediateDequeues() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let snapshot = bus.subscribe(afterSequence: nil, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(name: "one", category: "test", source: "test")
        XCTAssertEqual(snapshot.subscription.next(timeout: 1.0)?["name"] as? String, "one")

        let delayedPublish = expectation(description: "delayed event publish")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            bus.publish(name: "two", category: "test", source: "test")
            delayedPublish.fulfill()
        }

        let event = snapshot.subscription.next(timeout: 1.0)

        wait(for: [delayedPublish], timeout: 1.0)
        XCTAssertEqual(event?["name"] as? String, "two")
    }

    func testSlowSubscriptionClosesWhenPendingQueueIsFull() {
        let bus = CmuxEventBus(retainedEventLimit: 8, maxPendingEventsPerSubscription: 2)
        let snapshot = bus.subscribe(afterSequence: nil, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(name: "one", category: "test", source: "test")
        bus.publish(name: "two", category: "test", source: "test")
        bus.publish(name: "three", category: "test", source: "test")

        XCTAssertTrue(snapshot.subscription.isClosed)
        XCTAssertEqual(snapshot.subscription.closeReason, "pending event buffer exceeded 2 events")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testEventEncodingIsSingleLineJSON() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        bus.publish(
            name: "surface.input_sent",
            category: "surface",
            source: "test",
            payload: ["text": "hello\nworld"]
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().first)
        let line = try XCTUnwrap(CmuxEventBus.encodeLine(event))
        XCTAssertFalse(line.contains("\n"))

        let data = try XCTUnwrap(line.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(parsed["type"] as? String, "event")
        XCTAssertNotNil(parsed["boot_id"] as? String)
    }

    func testEncodingPreservesZeroAndOneNumbers() throws {
        let line = try XCTUnwrap(CmuxEventBus.encodeLine([
            "zero": NSNumber(value: Int64(0)),
            "one": NSNumber(value: Int64(1)),
            "truth": true,
        ]))

        XCTAssertTrue(line.contains("\"zero\":0"))
        XCTAssertTrue(line.contains("\"one\":1"))
        XCTAssertTrue(line.contains("\"truth\":true"))
    }

    func testStrictSequenceParsingRejectsBooleanAndFloatFrames() throws {
        XCTAssertEqual(CmuxEventBus.int64(NSNumber(value: Int64(42))), 42)
        XCTAssertEqual(CmuxEventBus.int64("42"), 42)
        XCTAssertNil(CmuxEventBus.int64(true))
        XCTAssertNil(CmuxEventBus.int64(NSNumber(value: 1.5)))
    }

    func testOversizedEventPayloadIsTruncatedBeforeRetention() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4, maxEventLineBytes: 1_024)

        bus.publish(
            name: "agent.log",
            category: "agent",
            source: "test",
            payload: ["message": String(repeating: "x", count: 20_000)]
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().first)
        XCTAssertEqual(event["payload_truncated"] as? Bool, true)

        let line = try XCTUnwrap(CmuxEventBus.encodeLine(event))
        XCTAssertLessThanOrEqual(line.utf8.count, 1_024)
    }

    func testNotificationSocketParamsRedactTextFields() throws {
        let redacted = CmuxSocketEventMapper.redactedNotificationParams([
            "title": "Secret title",
            "subtitle": "Private subtitle",
            "body": "Sensitive body",
            "redacted_fields": ["existing"],
            "workspace_id": "workspace",
        ])

        XCTAssertTrue(redacted["title"] is NSNull)
        XCTAssertTrue(redacted["subtitle"] is NSNull)
        XCTAssertTrue(redacted["body"] is NSNull)
        XCTAssertEqual(redacted["title_length"] as? Int, 12)
        XCTAssertEqual(redacted["subtitle_length"] as? Int, 16)
        XCTAssertEqual(redacted["body_length"] as? Int, 14)
        XCTAssertEqual(redacted["redacted_fields"] as? [String], ["existing", "title", "subtitle", "body"])
        XCTAssertEqual(redacted["workspace_id"] as? String, "workspace")
    }

    func testV1NotifySurfacePublishesSurfaceIdWithoutWorkspaceId() throws {
        let surfaceId = UUID()
        let bus = CmuxEventBus(retainedEventLimit: 4)

        CmuxSocketEventMapper.publish(command: "notify_surface \(surfaceId.uuidString) done", response: "OK", bus: bus)

        let event = try XCTUnwrap(bus.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "notification.requested")
        XCTAssertTrue(event["workspace_id"] is NSNull)
        XCTAssertEqual(event["surface_id"] as? String, surfaceId.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["surface_id"] as? String, surfaceId.uuidString)
    }

    func testV1MapperIgnoresNonSuccessResponses() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)

        CmuxSocketEventMapper.publish(command: "notify title", response: "OKAY", bus: bus)
        CmuxSocketEventMapper.publish(command: "notify title", response: "queued", bus: bus)
        CmuxSocketEventMapper.publish(command: "notify title", response: "ERROR: failed", bus: bus)

        XCTAssertTrue(bus.retainedSnapshot().isEmpty)
    }

    func testV2MapperPublishesToInjectedBus() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        let workspaceId = UUID().uuidString
        let command = """
        {"method":"workspace.rename","params":{"workspace_id":"\(workspaceId)"}}
        """
        let response = """
        {"ok":true,"result":{"workspace_id":"\(workspaceId)","title":"Renamed"}}
        """

        CmuxSocketEventMapper.publish(command: command, response: response, bus: bus)

        let event = try XCTUnwrap(bus.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "workspace.renamed")
        XCTAssertEqual(event["category"] as? String, "workspace")
        XCTAssertEqual(event["source"] as? String, "socket.v2")
        XCTAssertEqual(event["workspace_id"] as? String, workspaceId)
    }

    func testPublishAppendsDurableEventLog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(retainedEventLimit: 4, eventLogURL: logURL)

        bus.publish(name: "workspace.created", category: "workspace", source: "test")
        bus.publish(name: "surface.created", category: "surface", source: "test")
        await bus.flushEventLogForTesting()

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.count, 2)

        let secondData = try XCTUnwrap(lines.last?.data(using: .utf8))
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        XCTAssertEqual(second["name"] as? String, "surface.created")
    }

    func testDurableEventLogDropsOldestPendingLinesUnderBackpressure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-backpressure-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(
            retainedEventLimit: 8,
            eventLogURL: logURL,
            maxPendingEventLogLines: 2
        )

        bus.setEventLogFlushSuspendedForTesting(true)
        for index in 0..<5 {
            bus.publish(
                name: "agent.log",
                category: "agent",
                source: "test",
                payload: ["index": index]
            )
        }

        let backlog = bus.eventLogBacklogSnapshotForTesting()
        XCTAssertEqual(backlog.pending, 2)
        XCTAssertEqual(backlog.dropped, 3)

        bus.setEventLogFlushSuspendedForTesting(false)
        await bus.flushEventLogForTesting()

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let indexes = try lines.map { line in
            let data = try XCTUnwrap(line.data(using: .utf8))
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try XCTUnwrap(event["payload"] as? [String: Any])
            return try XCTUnwrap(payload["index"] as? Int)
        }
        XCTAssertEqual(indexes, [3, 4])
    }

    func testDurableEventLogRotatesAtByteLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-rotation-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(
            retainedEventLimit: 32,
            eventLogURL: logURL,
            maxEventLogBytes: 1_500,
            maxEventLineBytes: 1_024
        )

        for index in 0..<20 {
            bus.publish(
                name: "agent.log",
                category: "agent",
                source: "test",
                payload: ["index": index, "message": String(repeating: "x", count: 120)]
            )
        }
        await bus.flushEventLogForTesting()

        let rotatedURL = logURL.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
        XCTAssertLessThanOrEqual(try fileSize(logURL), 1_500)
        XCTAssertLessThanOrEqual(try fileSize(rotatedURL), 1_500)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return try XCTUnwrap(size).uint64Value
    }
}
