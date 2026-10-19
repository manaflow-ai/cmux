import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings

/// `debug.tab_switch`: the app's own time per tab switch (`SwitchFrameTimer`), apart from the socket
/// reply, which also waits for the daemon's confirm: intent (`PaneController.select`) to shown
/// selection (`applySelection`) to the Core Animation commit (cx-8w027.25, scripts/cmux-next/perf-gate.py).
@MainActor
enum DebugTabSwitch {
    static let timer = SwitchFrameTimer(owner: "debug.tab_switch")
    static var isRecording: Bool { timer.isRecording }
    static func began(_ owner: AnyObject) { timer.began(ObjectIdentifier(owner)) }
    static func shown(_ owner: AnyObject, in window: NSWindow?) { timer.shown(ObjectIdentifier(owner), in: window) }
}

extension SwitchFrameTimer {
    /// A debug socket method over this timer (`debug.tab_switch`, `debug.new_workspace`): `action`
    /// `start` or `stop` (else a read), then whether it records and its samples under `key`.
    func handle(_ params: [String: JSONValue], key: String) -> JSONValue {
        if params["action"]?.stringValue == "start" { start() } else if params["action"]?.stringValue == "stop" { stop() }
        return ["recording": .bool(isRecording), key: .array(samples.map { .object($0.mapValues { JSONValue.number($0) }) })]
    }
}
