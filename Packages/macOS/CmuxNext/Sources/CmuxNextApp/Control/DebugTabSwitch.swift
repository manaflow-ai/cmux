import AppKit
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextSettings
import CmuxNextSignposts

/// `debug.tab_switch`: the app's own time per tab switch (`SwitchFrameTimer`), apart from the socket
/// reply, which also waits for the daemon's confirm: intent (`PaneController.select`) to shown
/// selection (`applySelection`) to the Core Animation commit (cx-8w027.25, scripts/cmux-next/perf-gate.py).
/// Every switch is also, in every build and recording or not, the catalog's `switch.tab` interval
/// (`AppServices.tabSwitch`, `TabSwitchSignpost`): one os_signpost interval and one trace ring pair from the
/// intent, with the destination's kind, to the app's commit of the destination's content. The stages are
/// the timer's only; the trace ring holds catalog names, never a stage's text.
@MainActor
enum DebugTabSwitch {
    static let timer = SwitchFrameTimer(owner: "debug.tab_switch")
    static var isRecording: Bool { timer.isRecording }

    /// `pane` begins a switch to `tab` that it will show (the caller checked the run allows it and the pane draws);
    /// `keyInput` is the key whose binding runs now (``KeyInputScope``), if any.
    static func began(_ pane: PaneController, to tab: StripTabID, keyInput: KeyInputScope?) {
        // A key binding, else the input the switch answers (the key or click being dispatched, a page's carried click,
        // the press of the action run in progress): its age is the input stage.
        let inputTimestamp = keyInput?.timestamp ?? pane.services.inputDispatch.inputTimestamp, now = CACurrentMediaTime()
        // Only this switch's own input (not an event left over from a launch or a menu), as the timer reads it.
        let age = inputTimestamp.flatMap { now - $0 >= 0 && now - $0 < 1 ? (now - $0) * 1_000 : nil } ?? -1
        pane.services.tabSwitch.began(pane, to: tab.rawValue, kind: pane.tabSwitchKind(to: tab.rawValue), inputAgeMilliseconds: age)
        guard timer.isRecording else { return }
        timer.began(ObjectIdentifier(pane), at: now, inputTimestamp: inputTimestamp)
    }

    /// The switch of `owner` reached `stage`.
    static func mark(_ owner: AnyObject, _ stage: StaticString) {
        if timer.isRecording { timer.mark(ObjectIdentifier(owner), "\(stage)") }
    }

    static func kind(_ owner: AnyObject, _ kind: String) {
        if timer.isRecording { timer.setKind(ObjectIdentifier(owner), kind) }
    }

    /// `pane` resolved the content of the tab `key`; a live Chromium page takes the `switch.tab` request its show marks.
    static func content(_ pane: PaneController, _ content: TabContent, key: String) {
        kind(pane, content.switchKind)
        if case .browser(let entry) = content { pane.services.tabSwitch.shows(entry.tab, for: pane, key: key) }
    }

    /// `pane` put the content of the tab `key` in the pane this turn (the `view` stage): a `switch.tab` to `key`
    /// ends at this commit; a re-show of another tab ends nothing.
    static func contentShown(_ pane: PaneController, key: String?) {
        mark(pane, "view")
        if let key { pane.services.tabSwitch.contentShown(pane, key: key) }
    }

    static func shown(_ owner: AnyObject, in window: NSWindow?) {
        timer.shown(ObjectIdentifier(owner), in: window)
    }

    /// `pane` goes away or stops drawing (`suspend`): a switch it began and never showed ends here, as missed.
    static func forget(_ pane: PaneController) {
        pane.services.tabSwitch.forget(pane)
    }

    /// A window record write requested at `requested` (`CACurrentMediaTime`) was stored by the daemon.
    static func confirmed(requestedAt requested: CFTimeInterval) {
        timer.confirmed(requestedAt: requested)
    }
}

extension SwitchFrameTimer {
    /// A debug socket method over this timer (`debug.tab_switch`, `debug.new_workspace`): `action`
    /// `start` or `stop` (else a read), then whether it records and its samples under `key`, each
    /// with its content `kind` when one was set, and `confirms_ms` (the daemon's asynchronous confirms).
    func handle(_ params: [String: JSONValue], key: String) -> JSONValue {
        if params["action"]?.stringValue == "start" { start() } else if params["action"]?.stringValue == "stop" { stop() }
        let rows = samples.enumerated().map { index, values -> JSONValue in
            var row = values.mapValues { JSONValue.number($0) }
            if index < kinds.count, kinds[index] != "unknown" { row["kind"] = .string(kinds[index]) }
            return .object(row)
        }
        return ["recording": .bool(isRecording), key: .array(rows), "confirms_ms": .array(confirms.map { .number($0) })]
    }
}

extension PaneController {
    /// The `switch.tab` kind of a switch to the tab `key`: its page's, else warm while its content lives.
    func tabSwitchKind(to key: String) -> TabSwitchSignpost.Kind {
        if let page = services.cache.existingBrowser(key)?.tab { return services.tabSwitch.kind(of: page) }
        return services.cache.hasContent(for: key) || services.agentTabs.existingView(key) != nil
            || services.pages.existingView(key) != nil ? .warm : .cold
    }
}
