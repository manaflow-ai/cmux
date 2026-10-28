import Foundation
import Testing
import CmuxNextIPC

/// The wire types CmuxNextWireGen builds from cmux-tui/spec/sdk-schema.json,
/// decoding and encoding real daemon JSON: recursive tagged
/// unions, untagged unions told apart by their members, extensible enums,
/// schema defaults that are not written, and typed ids.
@Suite struct WireTypesTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// What `value` encodes to, as a JSON value (key order does not matter).
    private func json(_ value: some Encodable) throws -> WireJSON {
        try JSONDecoder().decode(WireJSON.self, from: JSONEncoder().encode(value))
    }

    @Test func aLayoutTreeRoundTripsAndKeepsAnUnknownNode() throws {
        let text = #"{"type":"split","split":4,"dir":"right","ratio":0.5,"#
            + #""a":{"type":"leaf","pane":1},"b":{"type":"stack","panes":[2,3],"expanded":3}}"#
        let layout = try decode(WireLayout.self, text)
        guard case .split(let split) = layout, case .leaf(let leaf) = split.a, case .stack(let stack) = split.b else {
            Issue.record("not a split of a leaf and a stack: \(layout)")
            return
        }
        #expect(split.split == WireSplitID(rawValue: 4) && split.dir == .right && split.ratio == 0.5)
        #expect(leaf.pane == WirePaneID(rawValue: 1) && stack.panes == [2, 3] && stack.panes.contains(stack.expanded))
        #expect(try decode(WireLayout.self, String(decoding: JSONEncoder().encode(layout), as: UTF8.self)) == layout)

        let future = try decode(WireLayout.self, #"{"type":"grid","cells":[1]}"#)
        #expect(future == .unknownVariant(tag: "grid", json: .object(["type": .string("grid"), "cells": .array([.integer(1)])])))
        #expect(try json(future) == .object(["type": .string("grid"), "cells": .array([.integer(1)])]))
    }

    @Test func aLiteralMemberTellsUntaggedVariantsApart() throws {
        let dead = try decode(WirePane.self, #"{"id":7,"dead":true}"#)
        #expect(dead == .deadPane(WireDeadPane(id: 7)))
        #expect(try json(dead) == .object(["id": .integer(7), "dead": .bool(true)]))
        // `dead: false` is no DeadPane, and without a name and tabs no LivePane.
        #expect(try decode(WirePane.self, #"{"id":7,"dead":false}"#) == .unknownVariant(.object(["id": .integer(7), "dead": .bool(false)])))
    }

    /// A pane that has every member of a live pane but a broken tab is a wire
    /// defect: it fails to decode instead of becoming an unknown variant.
    @Test func aCandidateVariantThatDoesNotDecodeFailsTheValue() throws {
        let broken = #"{"id":1,"name":"a","active_tab":2,"tabs":[{"surface":2}]}"#
        #expect(throws: DecodingError.self) { try decode(WirePane.self, broken) }
        #expect(throws: DecodingError.self) { try decode([WirePane].self, "[\(broken)]") }
    }

    /// An entity's own id is the type its references use (this test does not
    /// compile otherwise), and a pane id is no surface id.
    @Test func anEntityIDIsTheTypeOfItsReferences() throws {
        let paneIDs: [KeyPath<WireScreen, WirePaneID>] = [\.activePane]
        let ownPaneIDs: [KeyPath<WireLivePane, WirePaneID>] = [\.id]
        let deadPaneIDs: [KeyPath<WireDeadPane, WirePaneID>] = [\.id]
        let stackPaneIDs: [KeyPath<WireLayout.Stack, WirePaneID>] = [\.expanded]
        let surfaceIDs: [KeyPath<WireLivePane, WireSurfaceID>] = [\.activeTab]
        let screenIDs: [KeyPath<WireScreen, WireScreenID>] = [\.id]
        let workspaceIDs: [KeyPath<WireWorkspace, WireWorkspaceHandle>] = [\.id]
        #expect(paneIDs.count + ownPaneIDs.count + deadPaneIDs.count + stackPaneIDs.count == 4)
        #expect(surfaceIDs.count + screenIDs.count + workspaceIDs.count == 3)
        #expect(WireDeadPane(id: 7).id == WirePaneID(rawValue: 7))
        // A durable id accepts a JSON number, as the app's DaemonStringID does.
        #expect(try decode(WireTerminalID.self, "42") == "42")
    }

    @Test func anEnumTheAppDecodesKeepsValuesItDoesNotKnow() throws {
        #expect(try decode([WireAgentState].self, #"["idle","sleeping","unknown"]"#) == [.idle, .unknown("sleeping"), .unknown("unknown")])
        #expect(WireAgentState.unknown("sleeping").rawValue == "sleeping")
        // A schema `fallback` is where an unknown value goes instead.
        #expect(try decode(WireSizeDeviceKind.self, #""watch""#) == .unknown)
    }

    @Test func membersAtTheirDefaultAreNotWritten() throws {
        let policy = try decode(WireSizePolicy.self, "{}")
        #expect(policy == WireSizePolicy(fixed: nil, mode: .latest, priority: []))
        #expect(try json(policy) == .object([:]))
        #expect(try json(WireSizePolicy(mode: .smallest)) == .object(["mode": .string("smallest")]))
    }
}
