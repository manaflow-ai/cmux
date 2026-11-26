@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// The chat's Computer Use preview card sends `chat.computerUsePreview {action, x?, y?, size?}`: a
/// drag or a resize (`place`) and the chip that brings a hidden card back (`show`) join open and
/// close (Leo, 2026-11-22, asking for "the ability to drag it around and" hide it); the card the page
/// gets says where the daemon keeps it and whether it is hidden.
struct AgentPaneComputerUsePreviewActionTests {
    /// Params as the page's JSON arrives (JSONSerialization: numbers and booleans are NSNumbers).
    static func params(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    @Test func openCloseAndShowTakeOnlyTheirAction() {
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"open"}"#)) == .open)
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"close"}"#)) == .close)
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"show"}"#)) == .show)
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"show","x":1}"#)) == nil)
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"fly"}"#)) == nil)
    }

    @Test func aPlaceCarriesItsFractionsClampedAndItsSize() {
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place","x":0.25,"y":1}"#)) == .place(.init(x: 0.25, y: 1)))
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place","x":0,"y":0}"#)) == .place(.init(x: 0, y: 0)),
                "0 and 1 are fractions, not booleans")
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place","x":-2,"y":9}"#)) == .place(.init(x: 0, y: 1)))
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place","size":"full"}"#)) == .place(.init(size: .full)))
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place"}"#)) == nil, "a place changes something")
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place","x":true}"#)) == nil)
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place","x":"left"}"#)) == nil)
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place","size":"huge"}"#)) == nil)
        #expect(AgentPaneComputerUsePreview.action(Self.params(#"{"action":"place","x":0.5,"z":1}"#)) == nil)
    }

    @Test func thePagesCardSaysItsPlaceAndWhetherItIsHidden() {
        let plain = AgentPaneComputerUsePreview(session: "cua_1", app: "Notes", done: false, frame: "data:image/jpeg;base64,AA==")
        guard case .object(let object) = plain.json(at: Date()) else { Issue.record("not an object"); return }
        #expect(object["place"] == nil && object["hidden"] == nil, "a daemon that keeps no place sends none")
        let placed = AgentPaneComputerUsePreview(session: "cua_1", app: "Notes", done: false, frame: "data:image/jpeg;base64,AA==",
                                                 place: .init(x: 0, y: 0.5, size: .large), hidden: true)
        guard case .object(let moved) = placed.json(at: Date()) else { Issue.record("not an object"); return }
        #expect(moved["place"] == .object(["x": .number(0), "y": .number(0.5), "size": .string("large")]))
        #expect(moved["hidden"] == .bool(true))
    }
}
