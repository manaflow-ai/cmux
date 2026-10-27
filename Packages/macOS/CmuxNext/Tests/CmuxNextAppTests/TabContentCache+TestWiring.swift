@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextBrowser
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextMemory
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation

extension TabContentCache {
    /// A cache whose WebKit tabs place deadlines on a placer of their own over `mainWork` and follow app notices on
    /// an ``AppEvents`` on a center of their own (tests). It is in the test target, so the app, which must pass its one
    /// `AppServices.mainDeadlines` and `AppServices.appEvents`, cannot reach it.
    convenience init(daemon: DaemonService, chromium: ChromiumEngineSlot, fileInput: any WebFileInputAnswering,
                     afterFrame: @escaping (@escaping @MainActor () -> Void) -> Void = { AfterFrameCommit().run($0) },
                     resizes: ResizeCoordinator = ResizeCoordinator(), terminalModifiers: TerminalModifierWatch? = nil,
                     terminalPointerFrames: FrameInputCoalescers? = nil, mainWork: MainWorkScheduler,
                     imageCaches: ImageCacheShares = .legacy, gpuResidency: (any TerminalGPUResidency)? = nil) {
        self.init(daemon: daemon, chromium: chromium, fileInput: fileInput, afterFrame: afterFrame, resizes: resizes,
                  terminalModifiers: terminalModifiers, terminalPointerFrames: terminalPointerFrames, mainWork: mainWork,
                  deadlines: MainDeadlineScheduler(work: mainWork), appEvents: AppEvents(center: NotificationCenter()),
                  imageCaches: imageCaches, gpuResidency: gpuResidency)
    }
}
