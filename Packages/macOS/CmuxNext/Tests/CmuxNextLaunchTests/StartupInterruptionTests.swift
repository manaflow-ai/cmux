import AppKit
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextSignposts
import CmuxNextWakeups
import Testing

/// p08-startup-108: which launches are interrupted (Chrome's `WasMainWindowStartupInterrupted`,
/// components/startup_metric_utils/browser/startup_metric_utils.cc) and the marks that say so: one instant mark per
/// cause, the first followed by `launch.interrupted`, nothing after startup completes.
struct StartupInterruptionTests {
    private static let none = StartupInterruptionClassifier.Launch(hidden: false, firstWindowBehind: false,
                                                                   firstLaunch: false, recoveryNotice: false)

    @Test func aPlainLaunchIsNotInterrupted() {
        var classifier = StartupInterruptionClassifier()
        #expect(classifier.launch(Self.none).isEmpty)
        #expect(classifier.firstWindow(minimized: false, visible: false).isEmpty)
        #expect(classifier.firstWindow(minimized: false, visible: true).isEmpty)
        #expect(!classifier.isInterrupted)
    }

    @Test func eachLaunchCauseIsMarkedOnceAndTheFirstInterrupts() {
        var classifier = StartupInterruptionClassifier()
        let launch = StartupInterruptionClassifier.Launch(hidden: true, firstWindowBehind: true, firstLaunch: true,
                                                          recoveryNotice: true)
        #expect(classifier.launch(launch) == ["launch.interrupted.hidden", LaunchSlices.interruptedMark,
                                              "launch.interrupted.presentedBehind", "launch.interrupted.firstLaunch",
                                              "launch.interrupted.recoveryNotice"])
        #expect(classifier.causes == [.hidden, .presentedBehind, .firstLaunch, .recoveryNotice])
        #expect(classifier.launch(launch).isEmpty, "a cause is marked once")
    }

    /// No activation with no test screen orders the first window back: the person did not wait for it. On an agent's
    /// test screen (the benches) the window is in front and draws as a person's launch does.
    @Test func theWindowGoesBehindOnlyWhereThePlacementRuleOrdersItBack() {
        #expect(StartupInterruptionClassifier.Launch.firstWindowBehind(noActivate: true, testScreen: false))
        #expect(!StartupInterruptionClassifier.Launch.firstWindowBehind(noActivate: true, testScreen: true))
        #expect(!StartupInterruptionClassifier.Launch.firstWindowBehind(noActivate: false, testScreen: false))
        #expect(!StartupInterruptionClassifier.Launch.firstWindowBehind(noActivate: false, testScreen: true))
    }

    @Test func dialogsAreClassifiedByTheirIdentifier() {
        #expect(StartupInterruption.cause(ofDialog: "cmux.dialog.daemonPairing") == .daemonPrompt)
        #expect(StartupInterruption.cause(ofDialog: "cmux.dialog.terminalClipboardRead") == .daemonPrompt)
        #expect(StartupInterruption.cause(ofDialog: "cmux.dialog.restartDaemon") == .daemonPrompt)
        #expect(StartupInterruption.cause(ofDialog: StartupInterruption.settingConfirmationDialog) == .settingConfirmation)
        #expect(StartupInterruption.cause(ofDialog: "cmux.dialog.classicImport") == .dialog)
        #expect(StartupInterruption.cause(ofDialog: nil) == .dialog)
    }

    @Test func aWindowCoveredOnlyAfterItWasSeenIsOccluded() {
        var classifier = StartupInterruptionClassifier()
        #expect(classifier.firstWindow(minimized: false, visible: false).isEmpty,
                "just ordered in: the window server has not reported it visible yet")
        #expect(classifier.firstWindow(minimized: false, visible: true).isEmpty)
        #expect(classifier.firstWindow(minimized: false, visible: false) == ["launch.interrupted.occluded",
                                                                             LaunchSlices.interruptedMark])
    }

    @Test func aMinimizedWindowInterruptsAtOnce() {
        var classifier = StartupInterruptionClassifier()
        #expect(classifier.firstWindow(minimized: true, visible: false) == ["launch.interrupted.minimized",
                                                                            LaunchSlices.interruptedMark])
        #expect(classifier.dialogOpened(identifier: "cmux.dialog.daemonPairing") == ["launch.interrupted.daemonPrompt"],
                "a later cause is marked without a second interrupted mark")
    }

    @Test func nothingInterruptsAfterStartupCompletes() {
        var classifier = StartupInterruptionClassifier()
        _ = classifier.firstWindow(minimized: false, visible: true)
        classifier.close()
        #expect(classifier.firstWindow(minimized: true, visible: false).isEmpty)
        #expect(classifier.dialogOpened(identifier: nil).isEmpty)
        #expect(!classifier.isInterrupted)
    }

    @Test func everyCauseMarkStartsWithThePrefixTheBenchReads() {
        #expect(StartupInterruption.markPrefix == "launch.interrupted.")
        for cause in StartupInterruption.allCases {
            #expect(cause.mark == "launch.interrupted.\(cause.rawValue)")
            #expect(LaunchSlices.Milestone(mark: cause.mark) == nil, "a cause is no milestone")
        }
    }

    // MARK: The watch

    fileprivate final class SilentDialogHost: CmuxDialogHosting {
        func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {}
        func hide(_ dialog: CmuxDialogView) {}
    }

    fileprivate final class Marks {
        var sent: [String] = []
    }

    private static func spec(_ identifier: String?) -> CmuxDialogSpec {
        CmuxDialogSpec(title: "t", buttons: [.cancel()], identifier: identifier)
    }

    @Test func theWatchMarksTheLaunchAndEveryDialogUntilItCloses() {
        _ = NSApplication.shared
        let dialogs = CmuxDialogCenter(host: SilentDialogHost())
        let marks = Marks()
        let watch = LaunchInterruptionWatch(launch: Self.none, startup: nil, dialogs: dialogs) { marks.sent.append($0) }
        #expect(marks.sent.isEmpty)
        dialogs.present(Self.spec("cmux.dialog.daemonPairing"), in: .app) { _ in }
        #expect(marks.sent == ["launch.interrupted.daemonPrompt", LaunchSlices.interruptedMark])
        #expect(watch.isInterrupted)
        watch.close()
        dialogs.present(Self.spec("cmux.dialog.classicImport"), in: .app) { _ in }
        #expect(marks.sent.count == 2, "a dialog after startup completed interrupts nothing")
        #expect(watch.causes == [.daemonPrompt])
    }

    @Test func theWatchMarksTheLaunchCausesAtOnce() {
        let marks = Marks()
        let launch = StartupInterruptionClassifier.Launch(hidden: false, firstWindowBehind: true, firstLaunch: false,
                                                          recoveryNotice: false)
        let watch = LaunchInterruptionWatch(launch: launch, startup: nil, dialogs: CmuxDialogCenter(host: SilentDialogHost())) {
            marks.sent.append($0)
        }
        #expect(marks.sent == ["launch.interrupted.presentedBehind", LaunchSlices.interruptedMark])
        #expect(watch.causes == [.presentedBehind])
    }

    /// A watch on its own notification center, its window's state set by the test (``ReportedWindow``). Each test
    /// makes the `WindowEvents` through the watch's seam and keeps no reference to it: the watch must keep it.
    fileprivate struct WindowWatch {
        let center: NotificationCenter
        let marks: Marks
        let window: ReportedWindow
        let watch: LaunchInterruptionWatch

        init() {
            _ = NSApplication.shared
            let center = NotificationCenter(), marks = Marks()
            let window = ReportedWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                        backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let watch = LaunchInterruptionWatch(launch: StartupInterruptionTests.none, startup: nil,
                                                dialogs: CmuxDialogCenter(host: SilentDialogHost()),
                                                windowEvents: { WindowEvents(window: $0, center: center) }) { marks.sent.append($0) }
            watch.watchFirstWindow(window)
            (self.center, self.marks, self.window, self.watch) = (center, marks, window, watch)
        }

        func post(_ name: Notification.Name) { center.post(name: name, object: window) }
    }

    @Test func aWindowNeverSeenOnScreenIsNotCoveredByAnOcclusionNotice() {
        let test = WindowWatch()
        test.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(test.marks.sent.isEmpty, "never reported visible: an occlusion notice is no cover")
        #expect(!test.watch.isInterrupted)
    }

    @Test func aMiniaturizeNoticeMarksTheLaunchMinimized() {
        let test = WindowWatch()
        #expect(test.marks.sent.isEmpty)
        test.window.minimized = true
        test.post(NSWindow.didMiniaturizeNotification)
        #expect(test.marks.sent == ["launch.interrupted.minimized", LaunchSlices.interruptedMark])
        #expect(test.watch.causes == [.minimized])
    }

    @Test func aWindowCoveredAfterItWasSeenMarksTheLaunchOccluded() {
        let test = WindowWatch()
        test.window.visible = true
        test.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(test.marks.sent.isEmpty, "seen visible: no cause yet")
        test.window.visible = false
        test.post(NSWindow.didChangeOcclusionStateNotification)
        #expect(test.marks.sent == ["launch.interrupted.occluded", LaunchSlices.interruptedMark])
        #expect(test.watch.causes == [.occluded])
    }

    @Test func theWatchStopsObservingTheWindowWhenItCloses() {
        let test = WindowWatch()
        test.watch.close()
        test.window.minimized = true
        test.post(NSWindow.didMiniaturizeNotification)
        #expect(test.marks.sent.isEmpty, "a window change after startup completed interrupts nothing")
    }
}

/// A window whose miniaturized and occlusion state the test sets, as the window server would report them.
private final class ReportedWindow: NSWindow {
    var minimized = false
    var visible = false
    override var isMiniaturized: Bool { minimized }
    override var occlusionState: NSWindow.OcclusionState { visible ? .visible : [] }
}
