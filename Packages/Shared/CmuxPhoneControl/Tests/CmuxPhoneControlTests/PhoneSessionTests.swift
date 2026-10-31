import Foundation
import Testing

@testable import CmuxPhoneControl

@Suite("cmux.phone session")
struct PhoneSessionTests {
    @Test
    func mockDeviceRunsSnapshotActionChangedAndDuplicateFlow() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let opened = await server.handle(.request(id: "open", method: "session.open"))
        let sessionID = try #require(opened.first?.sessionID)

        let snapshot = await server.handle(.request(
            id: "snapshot",
            method: "screen.snapshot",
            sessionID: sessionID
        ))
        let frame = try #require(try snapshot.first?.result?.decode(PhoneScreenFrame.self))

        let params = PhoneJSONValue.object([
            "action_id": .string("action-1"),
            "screen_seq": .number(Double(frame.sequence)),
            "point": .object(["x": .number(0.5), "y": .number(0.5)]),
        ])
        let action = await server.handle(.request(
            id: "action",
            method: "action.tap",
            sessionID: sessionID,
            params: params
        ))
        #expect(action.count == 2)
        #expect(action[0].type == .response)
        #expect(action[1].method == "ui.changed")

        let duplicate = await server.handle(.request(
            id: "duplicate",
            method: "action.tap",
            sessionID: sessionID,
            params: .object([
                "action_id": .string("action-1"),
                "screen_seq": .number(Double(frame.sequence)),
                "point": .object(["x": .number(0.5), "y": .number(0.5)]),
            ])
        ))
        #expect(duplicate.count == 1)
        let receipt = try #require(try duplicate.first?.result?.decode(PhoneActionReceipt.self))
        #expect(receipt.duplicate)
        #expect(receipt.screenSequence == frame.sequence + 1)
    }

    @Test
    func reusingActionIDWithDifferentPayloadIsRejected() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let opened = await server.handle(.request(id: "open", method: "session.open"))
        let sessionID = try #require(opened.first?.sessionID)
        let params = PhoneJSONValue.object([
            "action_id": .string("same-id"),
            "point": .object(["x": .number(0.1), "y": .number(0.1)]),
        ])
        _ = await server.handle(.request(id: "first", method: "action.tap", sessionID: sessionID, params: params))
        let conflict = await server.handle(.request(
            id: "second",
            method: "action.tap",
            sessionID: sessionID,
            params: .object([
                "action_id": .string("same-id"),
                "point": .object(["x": .number(0.9), "y": .number(0.9)]),
            ])
        ))
        #expect(conflict.first?.error?.code == "action_id_conflict")
    }

    @Test
    func closingSessionAllowsAFreshSession() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let opened = await server.handle(.request(id: "open", method: "session.open"))
        let sessionID = try #require(opened.first?.sessionID)
        _ = await server.handle(.request(id: "close", method: "session.close", sessionID: sessionID))
        let reopened = await server.handle(.request(id: "reopen", method: "session.open"))
        #expect(reopened.first?.type == .response)
    }

    @Test
    func mismatchedCloseDoesNotDiscardSession() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let opened = await server.handle(.request(id: "open", method: "session.open"))
        _ = try #require(opened.first?.sessionID)
        let rejected = await server.handle(.request(
            id: "close-wrong-session",
            method: "session.close",
            sessionID: "other-session"
        ))
        #expect(rejected.first?.error?.code == "session_mismatch")

        let secondOpen = await server.handle(.request(id: "second-open", method: "session.open"))
        #expect(secondOpen.first?.error?.code == "session_exists")
    }

    @Test
    func staleScreenSequenceIsRejectedBeforeInput() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let opened = await server.handle(.request(id: "open", method: "session.open"))
        let sessionID = try #require(opened.first?.sessionID)
        _ = await server.handle(.request(id: "snapshot", method: "screen.snapshot", sessionID: sessionID))

        let result = await server.handle(.request(
            id: "action",
            method: "action.tap",
            sessionID: sessionID,
            params: .object([
                "action_id": .string("stale"),
                "screen_seq": .number(999),
                "point": .object(["x": .number(0.5), "y": .number(0.5)]),
            ])
        ))
        #expect(result.first?.type == .error)
        #expect(result.first?.error?.code == "stale_screen")
    }

    @Test
    func invalidCoordinatesAreRejected() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let opened = await server.handle(.request(id: "open", method: "session.open"))
        let sessionID = try #require(opened.first?.sessionID)
        let result = await server.handle(.request(
            id: "action",
            method: "action.tap",
            sessionID: sessionID,
            params: .object([
                "action_id": .string("bad-point"),
                "point": .object(["x": .number(2), "y": .number(0.5)]),
            ])
        ))
        #expect(result.first?.type == .error)
        #expect(result.first?.error?.code == "invalid_coordinates")
    }

    @Test
    func invalidSequenceAndDurationAreRejected() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let opened = await server.handle(.request(id: "open", method: "session.open"))
        let sessionID = try #require(opened.first?.sessionID)
        for params in [
            PhoneJSONValue.object([
                "action_id": .string("negative-seq"),
                "screen_seq": .number(-1),
                "point": .object(["x": .number(0.5), "y": .number(0.5)]),
            ]),
            PhoneJSONValue.object([
                "action_id": .string("long-duration"),
                "duration_ms": .number(60_001),
                "point": .object(["x": .number(0.5), "y": .number(0.5)]),
            ]),
        ] {
            let result = await server.handle(.request(
                id: UUID().uuidString,
                method: "action.tap",
                sessionID: sessionID,
                params: params
            ))
            #expect(result.first?.error?.code == "invalid_action")
        }
    }

    @Test
    func typingAndButtonActionsDoNotRequireCoordinates() async throws {
        let server = PhoneControlServer(driver: MockPhoneDriver())
        let opened = await server.handle(.request(id: "open", method: "session.open"))
        let sessionID = try #require(opened.first?.sessionID)

        let typed = await server.handle(.request(
            id: "type",
            method: "action.type",
            sessionID: sessionID,
            params: .object([
                "action_id": .string("type-1"),
                "text": .string("hello"),
            ])
        ))
        #expect(typed.count == 2)
        #expect(typed.first?.type == .response)

        let pressed = await server.handle(.request(
            id: "press",
            method: "action.press",
            sessionID: sessionID,
            params: .object([
                "action_id": .string("press-1"),
                "button": .string("home"),
            ])
        ))
        #expect(pressed.count == 2)
        #expect(pressed.first?.type == .response)
    }

    @Test
    func concurrentDuplicateActionsDoNotReachTheDriverTwice() async throws {
        let driver = BlockingPhoneDriver()
        let session = PhoneSession(driver: driver)
        let params = PhoneJSONValue.object([
            "action_id": .string("concurrent-tap"),
            "point": .object(["x": .number(0.5), "y": .number(0.5)]),
        ])
        let firstTask = Task {
            await session.handle(.request(id: "first", method: "action.tap", params: params))
        }
        await driver.waitForPerformStart()

        let second = await session.handle(.request(
            id: "second",
            method: "action.tap",
            params: params
        ))
        #expect(second.first?.error?.code == "action_in_progress")

        await driver.releasePerform()
        let first = await firstTask.value
        #expect(first.first?.type == .response)
        #expect(await driver.performCount == 1)
    }
}

private actor BlockingPhoneDriver: PhoneDriver {
    private let base = MockPhoneDriver()
    private var started = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var performCount = 0

    func device() async throws -> PhoneDevice { try await base.device() }

    func snapshot() async throws -> PhoneScreenFrame { try await base.snapshot() }

    func accessibilityTree() async throws -> PhoneUIElement? {
        try await base.accessibilityTree()
    }

    func perform(_ action: PhoneActionRequest) async throws -> PhoneActionReceipt {
        performCount += 1
        started = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return try await base.perform(action)
    }

    func waitForPerformStart() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func releasePerform() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
