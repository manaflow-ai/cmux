import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTabs

/// `debug.motion`: the wiring of `MotionDebug` (CmuxNextDesign), which documents its actions.
enum DebugMotion {
    /// - Parameter commitProbe: the handler's own commit timer (`AppControl` owns it).
    static func handle(_ params: [String: JSONValue], _ services: AppServices? = nil, commitProbe: MotionCommitProbe? = nil) -> JSONValue {
        if params["action"]?.stringValue == "trajectory" { return MotionParityCorpus().document }
        let windows = services?.windows.controllers.compactMap(\.window) ?? []
        let report = MotionDebug.handle(params.mapValues(\.foundationObject), windows: windows,
                                        samplers: [TabStripDebug.motionSample, SidebarContainerView.motionSample],
                                        commitProbe: commitProbe)
        return JSONValue(foundation: report) ?? .null
    }
}
