import AppKit
import CmuxNextControl
import CmuxNextHomeEngine
import CmuxNextSettings

// `debug.chief_settings` (DEBUG builds), for captures of the Chief Settings popover
// (scripts/cmux-next/media/tours/chief-settings.json): a capture mini runs no Chief brain, so
// `fixture: "last-turn"` has the open popover show a fixed brain answer
// (`HomeChiefSettingsView.showCaptureFixture`), and `details` opens or closes Diagnostics'
// disclosure. The reply says whether a popover was open.
enum DebugChiefSettings {
    static func register(on router: ControlRouter?) {
        #if DEBUG
        router?.register([
            .mainActor("debug.chief_settings") { call in .value(handle(call.params)) },
        ])
        #endif
    }
}

#if DEBUG
extension DebugChiefSettings {
    static func handle(_ params: [String: JSONValue]) -> JSONValue {
        let shown = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == "cmux.home.chiefSettings" }
        guard let view = shown.lazy.compactMap({ $0.contentView.flatMap(settingsView(in:)) }).first else {
            return .object(["error": .string("no Chief Settings popover is open")])
        }
        if params["fixture"]?.stringValue == "last-turn" { view.showCaptureFixture() }
        if let details = params["details"]?.boolValue { view.showDiagnosticsDetails(details) }
        return .object(["open": .bool(true)])
    }

    private static func settingsView(in view: NSView) -> HomeChiefSettingsView? {
        if let settings = view as? HomeChiefSettingsView { return settings }
        for subview in view.subviews {
            if let settings = settingsView(in: subview) { return settings }
        }
        return nil
    }
}
#endif
