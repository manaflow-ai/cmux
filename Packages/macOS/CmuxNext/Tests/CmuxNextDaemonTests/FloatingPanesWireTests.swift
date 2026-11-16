import Foundation
import Testing
@testable import CmuxNextDaemon

/// Floating panes on the wire (`floating-panes-v1`): a screen's `floating` list, back to front, and the
/// `float-pane` request that floats a pane, puts it back or gives it a frame.
struct FloatingPanesWireTests {
    private static let layout = #"{"type":"split","split":9,"dir":"right","ratio":0.5,"a":{"type":"leaf","pane":1},"b":{"type":"leaf","pane":2}}"#

    private static func screen(_ floating: String?) throws -> ScreenSnapshot {
        let field = floating.map { #","floating":\#($0)"# } ?? ""
        return try JSONDecoder().decode(ScreenSnapshot.self, from: Data(#"{"id":4,"layout":\#(layout)\#(field)}"#.utf8))
    }

    private static func fields(_ request: FloatPaneRequest) throws -> [String: JSONValue] {
        guard case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 7)) else { return [:] }
        return fields
    }

    @Test func aScreenListsItsFloatingPanesBackToFront() throws {
        let screen = try Self.screen(#"[{"pane":2,"x":0.5,"y":0.25,"w":0.4,"h":0.3},{"pane":1,"x":0,"y":0,"w":0.15,"h":1}]"#)
        #expect(screen.floating == [
            FloatingPaneSnapshot(pane: PaneID(rawValue: 2), frame: .init(x: 0.5, y: 0.25, w: 0.4, h: 0.3)),
            FloatingPaneSnapshot(pane: PaneID(rawValue: 1), frame: .init(x: 0, y: 0, w: 0.15, h: 1)),
        ])
        #expect(screen.layout != .unknown, "a floating pane stays a leaf of the layout")
    }

    /// A daemon without the capability sends no list, and a list this client cannot read is no list: each pane is
    /// still a leaf of the layout, so the screen shows it tiled.
    @Test func aScreenWithNoListOrABadListHasNoFloatingPane() throws {
        #expect(try Self.screen(nil).floating.isEmpty)
        #expect(try Self.screen("[]").floating.isEmpty)
        let bad = try Self.screen(#"[{"pane":2,"x":0.5}]"#)
        #expect(bad.floating.isEmpty)
        #expect(bad.id == ScreenID(rawValue: 4))
        #expect(bad.layout != .unknown)
    }

    @Test func aLayoutChangeCarriesTheList() throws {
        let json = #"{"layout":\#(Self.layout),"floating":[{"pane":2,"x":0.1,"y":0.2,"w":0.3,"h":0.4}]}"#
        let delta = try JSONDecoder().decode(ScreenLayoutDelta.self, from: Data(json.utf8))
        #expect(delta.floating == [FloatingPaneSnapshot(pane: PaneID(rawValue: 2), frame: .init(x: 0.1, y: 0.2, w: 0.3, h: 0.4))])
        let plain = try JSONDecoder().decode(ScreenLayoutDelta.self, from: Data(#"{"layout":\#(Self.layout)}"#.utf8))
        #expect(plain.floating.isEmpty)
    }

    /// The store's record of a screen takes the list from its first snapshot, from a later snapshot and from a
    /// layout change, so each reader of the record sees the daemon's list.
    @MainActor @Test func theScreenRecordFollowsTheList() throws {
        let entry = #"{"pane":2,"x":0.5,"y":0.25,"w":0.4,"h":0.3}"#
        let pane = FloatingPaneSnapshot(pane: PaneID(rawValue: 2), frame: .init(x: 0.5, y: 0.25, w: 0.4, h: 0.3))
        let record = ScreenModel(try Self.screen("[\(entry)]"))
        #expect(record.floating == [pane])
        record.update(try Self.screen(nil))
        #expect(record.floating.isEmpty, "a later snapshot with no list ends the list")
        let change = #"{"layout":\#(Self.layout),"floating":[\#(entry)]}"#
        record.applyLayout(try JSONDecoder().decode(ScreenLayoutDelta.self, from: Data(change.utf8)))
        #expect(record.floating == [pane])
        record.applyLayout(try JSONDecoder().decode(ScreenLayoutDelta.self, from: Data(#"{"layout":\#(Self.layout)}"#.utf8)))
        #expect(record.floating.isEmpty, "a layout change with no list ends the list")
    }

    @Test func theCapabilityIsOptionalAndTheRequestNeedsIt() {
        #expect(DaemonCapability.floatingPanes.rawValue == "floating-panes-v1")
        #expect(DaemonCapability.optional.contains("floating-panes-v1"))
        #expect(!DaemonCapability.required.contains("floating-panes-v1"))
        #expect(FloatPaneRequest.requiredCapability == "floating-panes-v1")
    }

    @Test func aToggleRequestNamesOnlyThePane() throws {
        let fields = try Self.fields(FloatPaneRequest(pane: PaneID(rawValue: 2)))
        #expect(fields["cmd"] == .string("float-pane"))
        #expect(fields["pane"] == .number(2))
        for key in ["mode", "x", "y", "w", "h", "transaction"] {
            #expect(fields[key] == nil, "a plain request has no \(key)")
        }
    }

    @Test func aFrameRequestCarriesAllFourNumbers() throws {
        let frame = FloatingPaneSnapshot.Frame(x: 0.25, y: 0.5, w: 0.5, h: 0.25)
        let fields = try Self.fields(FloatPaneRequest(pane: PaneID(rawValue: 2), mode: .on, frame: frame, transaction: 11))
        #expect(fields["mode"] == .string("on"))
        #expect(fields["x"] == .number(0.25))
        #expect(fields["y"] == .number(0.5))
        #expect(fields["w"] == .number(0.5))
        #expect(fields["h"] == .number(0.25))
        #expect(fields["transaction"] == .number(11))
        #expect(try Self.fields(FloatPaneRequest(pane: PaneID(rawValue: 2), mode: .off))["mode"] == .string("off"))
    }

    @Test func theAnswerSaysIfThePaneFloatsAndIfTheScreenChanged() throws {
        let json = #"{"screen":4,"floating":true,"changed":false,"frame":{"x":0.1,"y":0.1,"w":0.5,"h":0.5}}"#
        let answer = try JSONDecoder().decode(FloatPaneRequest.Response.self, from: Data(json.utf8))
        #expect(answer.floating)
        #expect(!answer.changed)
    }

    /// The answer of `split` names the pane it made: a new floating pane is that pane.
    @Test func theAnswerOfASplitNamesItsPane() throws {
        let created = try JSONDecoder().decode(SurfaceCreated.self, from: Data(#"{"surface":8,"pane":5}"#.utf8))
        #expect(created.pane == PaneID(rawValue: 5))
        #expect(try JSONDecoder().decode(SurfaceCreated.self, from: Data(#"{"surface":8}"#.utf8)).pane == nil)
    }
}
