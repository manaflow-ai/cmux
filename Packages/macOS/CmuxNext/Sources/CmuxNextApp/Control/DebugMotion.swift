import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTabs

/// `debug.motion`: the wiring of `MotionDebug` (CmuxNextDesign), which documents its actions.
enum DebugMotion {
    static func handle(_ params: [String: JSONValue], _ services: AppServices? = nil) -> JSONValue {
        if params["action"]?.stringValue == "trajectory" { return MotionParityCorpus().document }
        let windows = services?.windows.controllers.compactMap(\.window) ?? []
        let report = MotionDebug.handle(params.mapValues(\.foundationObject), windows: windows,
                                        samplers: [TabStripDebug.motionSample, SidebarContainerView.motionSample])
        return JSONValue(foundation: report) ?? .null
    }
}
