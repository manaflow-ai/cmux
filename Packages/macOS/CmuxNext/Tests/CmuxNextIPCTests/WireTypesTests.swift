import Foundation
import Testing
import CmuxNextIPC

/// The wire types CmuxNextWireGen builds from cmux-tui/spec/sdk-schema.json
/// (p05-ipc-020), decoding and encoding real daemon JSON: recursive tagged
/// unions, untagged unions told apart by a literal, extensible enums, schema
/// defaults that are not written, and typed ids.
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
        let layout = try decode(Layout.self, text)
        guard case .split(let split) = layout, case .leaf(let leaf) = split.a, case .stack(let stack) = split.b else {
            Issue.record("not a split of a leaf and a stack: \(layout)")
            return
        }
        #expect(split.split == SplitID(rawValue: 4) && split.dir == .right && split.ratio == 0.5)
        #expect(leaf.pane == PaneID(rawValue: 1) && stack.panes == [2, 3] && stack.expanded == 3)
        #expect(try decode(Layout.self, String(decoding: JSONEncoder().encode(layout), as: UTF8.self)) == layout)

        let future = try decode(Layout.self, #"{"type":"grid","cells":[1]}"#)
        #expect(future == .unknownVariant(tag: "grid", json: .object(["type": .string("grid"), "cells": .array([.integer(1)])])))
        #expect(try json(future) == .object(["type": .string("grid"), "cells": .array([.integer(1)])]))
    }

    @Test func aLiteralMemberTellsUntaggedVariantsApart() throws {
        let dead = try decode(Pane.self, #"{"id":7,"dead":true}"#)
        #expect(dead == .deadPane(DeadPane(id: 7)))
        #expect(try json(dead) == .object(["id": .integer(7), "dead": .bool(true)]))
        // `dead: false` is no DeadPane, and without a name and tabs no LivePane.
        #expect(try decode(Pane.self, #"{"id":7,"dead":false}"#) == .unknownVariant(.object(["id": .integer(7), "dead": .bool(false)])))
    }

    @Test func anEnumTheAppDecodesKeepsValuesItDoesNotKnow() throws {
        #expect(try decode([AgentState].self, #"["idle","sleeping","unknown"]"#) == [.idle, .unknown("sleeping"), .unknown("unknown")])
        #expect(AgentState.unknown("sleeping").rawValue == "sleeping")
        // A schema `fallback` is where an unknown value goes instead.
        #expect(try decode(SizeDeviceKind.self, #""watch""#) == .unknown)
    }

    @Test func membersAtTheirDefaultAreNotWritten() throws {
        let policy = try decode(SizePolicy.self, "{}")
        #expect(policy == SizePolicy(fixed: nil, mode: .latest, priority: []))
        #expect(try json(policy) == .object([:]))
        #expect(try json(SizePolicy(mode: .smallest)) == .object(["mode": .string("smallest")]))
    }
}
