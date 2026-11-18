import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// What a chat's last page held goes to the pool's page with its adopt event (decision 2026-11-16): the state's
/// bound, its place, its shape on the event, and the paint report's word that the page took it.
/// `ChatReturnWakeTests` (app tests) holds the tab's store to the same change.
@MainActor @Suite
struct AgentPaneWakeAdoptTests {
    /// A state whose one chip holds `bytes` bytes of file content.
    static func state(ofBytes bytes: Int) -> AgentPaneWakeState {
        AgentPaneWakeState(attachments: [AgentPaneWakeState.Attachment(
            id: "big", kind: "image", name: "big.png", mimeType: "image/png", size: Double(bytes), data: String(repeating: "A", count: bytes))])
    }

    @Test func aStateAtTheBoundGoesWithTheEventAndOneByteOverItDoesNot() {
        let limit = AgentPaneWakeState.adoptEventLimit
        #expect(Self.state(ofBytes: limit).contentBytes == limit)
        #expect(Self.state(ofBytes: limit).fitsAdoptEvent, "a state at the bound does not go with the event")
        #expect(!Self.state(ofBytes: limit + 1).fitsAdoptEvent, "a state one byte over the bound goes with the event")
        #expect(AgentPaneWakeState().fitsAdoptEvent)
    }

    /// The count is of UTF-8 bytes, over every field that holds content of no fixed size.
    @Test func theBoundCountsEachFieldThatHoldsContent() {
        let chips = [AgentPaneWakeState.Attachment(id: "a", kind: "image", name: "a.png", mimeType: "image/png", size: 4, data: "iVBO"),
                     AgentPaneWakeState.Attachment(id: "b", kind: "text", name: "b.txt", mimeType: "text/plain", size: 3, text: "é1")]
        let state = AgentPaneWakeState(attachments: chips, shell: true, shellText: "ls",
                                       subagentDrafts: ["d1": AgentPaneWakeState.SubagentDraft(text: "hello", at: 1),
                                                        "d2": AgentPaneWakeState.SubagentDraft(text: nil, at: 2)])
        // 4 (the image) + 3 (`é` is 2 bytes) + 2 (the command) + 5 (the one draft with text).
        #expect(state.contentBytes == 14)
    }

    /// The place the released page left stands over the kept one; a page that did not know its place says nothing.
    @Test func theStatesPlaceIsAPlaceOrTheLatestMessageOrUnknown() {
        let anchor = AgentPaneScrollAnchor(rowId: "row-12", offset: 40)
        let place: AgentPaneScrollAnchor?? = .some(anchor)
        let latest: AgentPaneScrollAnchor?? = .some(nil)
        let unknown: AgentPaneScrollAnchor?? = nil
        #expect(AgentPaneWakeState(scrollAnchor: anchor).adoptedPlace == place)
        #expect(AgentPaneWakeState(atLatest: true).adoptedPlace == latest)
        #expect(AgentPaneWakeState(shell: true).adoptedPlace == unknown)
        // The state's place stands over the tab's kept one; a state that does not know its place leaves the kept one.
        let kept: AgentPaneScrollAnchor?? = .some(AgentPaneScrollAnchor(rowId: "row-3", offset: 0))
        #expect(AgentPaneWakeState.adoptPlace(of: AgentPaneWakeState(scrollAnchor: anchor), kept: kept) == place)
        #expect(AgentPaneWakeState.adoptPlace(of: AgentPaneWakeState(atLatest: true), kept: kept) == latest)
        #expect(AgentPaneWakeState.adoptPlace(of: AgentPaneWakeState(shell: true), kept: kept) == kept)
        #expect(AgentPaneWakeState.adoptPlace(of: nil, kept: unknown) == unknown)
    }

    /// The event's `wake` is the JSON that the handshake's `wake` has, so one function of the page reads both.
    @Test func theAdoptEventCarriesTheStateInTheHandshakesShape() throws {
        let state = AgentPaneWakeState(
            attachments: [AgentPaneWakeState.Attachment(id: "a1", kind: "image", name: "shot.png", mimeType: "image/png", size: 4, data: "iVBO")],
            shell: true, shellText: "git status", atLatest: true)
        func detail(wake: JSONValue?) throws -> JSONValue {
            let text = AgentPaneView.adoptEventDetail(session: "s-1", revealTurn: nil, tail: nil, place: state.adoptedPlace, wake: wake)
            return try #require(JSONValue(foundation: try JSONSerialization.jsonObject(with: Data(text.utf8))))
        }
        let carried = try detail(wake: try #require(state.adoptEventValue))
        let handshake = try #require(JSONValue(foundation: try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))))
        #expect(carried["wake"] == handshake)
        #expect(carried["wake"]?["shellText"] == .string("git status"))
        #expect(carried["wake"]?["attachments"] == .array([.object([
            "id": .string("a1"), "kind": .string("image"), "name": .string("shot.png"), "mimeType": .string("image/png"),
            "size": .number(4), "data": .string("iVBO"),
        ])]))
        // At its latest message: the event says that no place is kept.
        #expect(carried["scrollAnchor"] == .null)
        // No state: the event has no `wake`.
        #expect(try detail(wake: nil)["wake"] == nil)
    }

    /// The page says with a paint report that it took the state of its adopt event. A value that is no Bool, or
    /// no value, says nothing.
    @Test func aPaintReportSaysThatThePageTookTheState() {
        func applied(_ params: [String: Any]) -> Bool? {
            guard case .painted(_, _, let appliedWake) = AgentPaneRequest(body: ["method": "pane.painted", "params": params]) else { return nil }
            return appliedWake
        }
        #expect(applied(["appliedWake": true]) == true)
        #expect(applied(["appliedWake": "yes"]) == false)
        #expect(applied(["drewKeptTail": true, "settled": true]) == false)
    }
}
