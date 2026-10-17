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
                "point": .object(["x": .number(0.5), "y": .number(0.5)]),
            ])
        ))
        let receipt = try #require(try duplicate.first?.result?.decode(PhoneActionReceipt.self))
        #expect(receipt.duplicate)
        #expect(receipt.screenSequence == frame.sequence + 1)
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
}
