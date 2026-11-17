import AppKit
import class CmuxNextAgentPane.AgentPaneLaunchTimings
import CmuxNextDaemonService
import CmuxNextQuit

/// The background ready copy's reach into the App (`app.backgroundReady`, ``BackgroundReadyController``): one-line
/// forwards to the window manager, the quit's saves that end nothing (``QuitCoordinator/quitSteps(_:)``'s) and the quit.
extension AppServices: BackgroundReadyHost {
    var backgroundReadyShownWindows: [NSWindow] { windows.controllers.compactMap(\.window).filter(\.isVisible) }
    func backgroundReadyWindowID(_ window: NSWindow) -> String? { windows.owner(of: window)?.state.id }
    var backgroundReadyFrontIsKey: Bool { windows.active?.window?.isKeyWindow == true }
    var backgroundReadyFrontChatPainted: Bool? { windows.active?.content?.focusedPane?.selectedAgentView?.model.hasPainted }
    func backgroundReadyCaptureGeometry() { windows.captureGeometry() }
    func backgroundReadySaveWindowRecords() async { await windows.recordSaver.flushSaves() }
    func backgroundReadySaveSidebar() async { await sidebarSnapshots.flush() }
    func backgroundReadySaveHomeCache() async { await home.flushCacheForQuit() }
    func backgroundReadySaveLaunchRecord() async { await windows.recordSaver.launchRecord.flush() }
    func backgroundReadyReopen(windowID: String) { _ = windows.reopenClosedWindow(id: windowID) }
    func backgroundReadyReopenOrCreate() { windows.reopenOrCreateWindow() }
    func backgroundReadyRestore() { windows.restoreWhenLoaded() }
    var backgroundReadyIsSafeRestart: Bool { crashRecovery.recovery.isSafeRestart }
    func backgroundReadyStartChromiumWarmup() { startChromiumWarmup() }
    func backgroundReadyListenForLaunchMarks(_ listener: @escaping @Sendable (String) -> Void) { AgentPaneLaunchTimings.shared.listen(listener) }
    func backgroundReadyRequestQuit(_ origin: QuitOrigin) { quit.requestQuit(origin) }
    /// In `applicationDidFinishLaunching`, while its open-application event is current: a login item's launch.
    static func launchedAsLoginItemNow() -> Bool { BackgroundReadyLoginItem.launchedAsLoginItem(NSAppleEventManager.shared().currentAppleEvent) }
}
