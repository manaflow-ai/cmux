import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextLaunchCapture

// Each window's launch image (CmuxNextLaunchCapture): one-line forwards to the App's owners.
extension AppServices: LaunchCaptureHost {
    var launchCaptureLive: Bool { windows.restored && !windows.isTerminating }
    var launchCaptureWindowIDs: [String] { windows.controllers.map(\.state.id) }
    func launchCaptureAllows(_ id: String) -> Bool { !windows.isIncognito(window: id) }
    func launchCaptureWindow(_ id: String) -> NSWindow? { windows.controller(for: id)?.window }
    func launchCaptureBackground(_ id: String) -> CGColor? { windows.controller(for: id)?.themeScope.tokens.surfaceBackground.cgColor }
    func launchCaptureBrowserPages(_ id: String) -> [LaunchCaptureBrowserPage] { windows.controller(for: id)?.content?.panes.values.compactMap(cache.launchCapturePage) ?? [] }
    var launchRecordImages: LaunchRecordImages { windows.recordSaver.launchRecord.images }
    func launchRecordChanged() { windows.recordSaver.launchRecord.schedule() }
    func launchRecordForget(_ id: String) { windows.recordSaver.launchRecord.setImage(nil, forWindow: id) }
}
