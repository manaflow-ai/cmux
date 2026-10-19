import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextSettings
import os

/// `debug.tab_switch`: the app's own time per tab switch (`SwitchFrameTimer`), apart from the socket
/// reply, which also waits for the daemon's confirm: intent (`PaneController.select`) to shown
/// selection (`applySelection`) to the Core Animation commit (cx-8w027.25, scripts/cmux-next/perf-gate.py).
/// Every switch is also an `OSSignposter` interval (subsystem `com.cmuxterm.app.next`, category
/// `tab-switch`, name `switch`) with one event per stage, for Instruments, recording or not.
@MainActor
enum DebugTabSwitch {
    private static let timer = SwitchFrameTimer(owner: "debug.tab_switch")
    private static let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "tab-switch")
    private static var intervals: [ObjectIdentifier: (id: OSSignpostID, state: OSSignpostIntervalState)] = [:]
    /// The timestamp of the key whose binding runs now (a synthetic key never becomes `NSApp.currentEvent`).
    private static var input: TimeInterval?
    static var isRecording: Bool { timer.isRecording }

    /// Runs `body` with `input` (an `NSEvent.timestamp`) as the start of any switch it begins.
    static func handling(input timestamp: TimeInterval, _ body: () -> Void) {
        let previous = input
        input = timestamp
        defer { input = previous }
        body()
    }

    static func began(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        if signposter.isEnabled {
            if let open = intervals.removeValue(forKey: key) { signposter.endInterval("switch", open.state, "superseded") }
            let id = signposter.makeSignpostID()
            intervals[key] = (id, signposter.beginInterval("switch", id: id))
        }
        guard timer.isRecording else { return }
        // A key binding or click being handled now: its age is the input stage.
        let event = NSApp.currentEvent
        let click = event.flatMap { [.leftMouseDown, .leftMouseUp].contains($0.type) ? $0.timestamp : nil }
        timer.began(key, inputTimestamp: input ?? click)
    }

    /// The switch of `owner` reached `stage`.
    static func mark(_ owner: AnyObject, _ stage: StaticString) {
        if let open = intervals[ObjectIdentifier(owner)] {
            signposter.emitEvent(stage, id: open.id)
        }
        if timer.isRecording { timer.mark(ObjectIdentifier(owner), "\(stage)") }
    }

    static func kind(_ owner: AnyObject, _ kind: String) {
        if timer.isRecording { timer.setKind(ObjectIdentifier(owner), kind) }
    }

    static func shown(_ owner: AnyObject, in window: NSWindow?) {
        if let open = intervals.removeValue(forKey: ObjectIdentifier(owner)) { signposter.endInterval("switch", open.state) }
        timer.shown(ObjectIdentifier(owner), in: window)
    }

    /// A window record write requested at `requested` (`CACurrentMediaTime`) was stored by the daemon.
    static func confirmed(requestedAt requested: CFTimeInterval) {
        timer.confirmed(requestedAt: requested)
    }

    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        switch params["action"]?.stringValue ?? "read" {
        case "start": timer.start()
        case "stop": timer.stop()
        default: break
        }
        let rows = zip(timer.samples, timer.kinds).map { values, kind -> JSONValue in
            var row = values.mapValues { JSONValue.number($0) }
            row["kind"] = .string(kind)
            return .object(row)
        }
        return ["recording": .bool(timer.isRecording), "switches": .array(rows),
                "confirms_ms": .array(timer.confirms.map { .number($0) })]
    }
}
