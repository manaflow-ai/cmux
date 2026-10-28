public import AppKit
public import CmuxNextDesign
public import CmuxNextWakeups

/// Feeds the launch's ``StartupInterruptionClassifier`` from `applicationDidFinishLaunching` until startup completes,
/// and sends each mark it returns (p08-startup-108): the launch's own causes at once, every cmux dialog opened before
/// completion, and the first window's miniaturize and occlusion notices. At completion
/// (``StartupScheduler/whenCompleteFirst(_:)``, before the `startup_complete` mark) it closes the classifier and stops
/// observing, so a reader of `startup_complete` (the hang report's launch record, task 115) reads the final answer.
///
/// ```swift
/// let watch = LaunchInterruptionWatch(launch: facts, startup: order.startup, dialogs: .shared) { DebugTimings.markLaunch($0) }
/// services.windows.onPresent = { controller in watch.watchFirstWindow(controller.window) }
/// ```
@MainActor
public final class LaunchInterruptionWatch {
    private var classifier = StartupInterruptionClassifier()
    private let mark: @MainActor (String) -> Void
    private let dialogs: CmuxDialogCenter
    private let windowEvents: @MainActor (NSWindow) -> WindowEvents
    private var dialogObserver: UUID?
    /// The first window's notices, kept until ``close()``: a subscription holds its fan-out weakly, and only
    /// ``WindowEvents/of(_:center:)`` ties one to its window.
    private var firstWindowEvents: WindowEvents?
    private var windowSubscriptions: [EventSubscription] = []
    private var watchesWindow = false

    /// Sends `launch`'s causes now and observes `dialogs` until `startup` completes.
    ///
    /// - Parameters:
    ///   - launch: What is known before any window.
    ///   - startup: The launch's startup scheduler; nil (tests) keeps watching until ``close()``.
    ///   - dialogs: The app's dialog center.
    ///   - windowEvents: A window's notices (tests pass their own center's).
    ///   - mark: Sends one launch mark (`DebugTimings.markLaunch`).
    public init(launch: StartupInterruptionClassifier.Launch, startup: StartupScheduler?, dialogs: CmuxDialogCenter,
                windowEvents: @escaping @MainActor (NSWindow) -> WindowEvents = { WindowEvents.of($0) },
                mark: @escaping @MainActor (String) -> Void) {
        self.mark = mark
        self.dialogs = dialogs
        self.windowEvents = windowEvents
        send(classifier.launch(launch))
        dialogObserver = dialogs.observe { [weak self] event in
            guard let self, case .opened(let record) = event else { return }
            send(classifier.dialogOpened(identifier: record.spec.identifier))
        }
        startup?.whenCompleteFirst { [weak self] _ in self?.close() }
    }

    /// The causes so far, in the order they came.
    public var causes: [StartupInterruption] { classifier.causes }

    /// Whether the launch is interrupted.
    public var isInterrupted: Bool { classifier.isInterrupted }

    /// Watches the first presented window (later calls do nothing): minimized now, or minimized or covered after it
    /// was seen visible, before startup completes.
    public func watchFirstWindow(_ window: NSWindow?) {
        guard let window, !watchesWindow, !classifier.isClosed else { return }
        watchesWindow = true
        let events = windowEvents(window)
        firstWindowEvents = events
        let changed: @MainActor () -> Void = { [weak self, weak window] in
            guard let self, let window else { return }
            send(classifier.firstWindow(minimized: window.isMiniaturized, visible: window.occlusionState.contains(.visible)))
        }
        windowSubscriptions = [
            events.subscribe(NSWindow.didMiniaturizeNotification, owner: "LaunchInterruptionWatch", changed),
            events.subscribe(NSWindow.didChangeOcclusionStateNotification, owner: "LaunchInterruptionWatch", changed),
        ]
        // Just ordered in: the window server has not reported it visible yet, so only a minimized window counts now.
        send(classifier.firstWindow(minimized: window.isMiniaturized, visible: false))
    }

    /// Startup completed: closes the classifier and stops observing.
    public func close() {
        classifier.close()
        if let dialogObserver { dialogs.stopObserving(dialogObserver) }
        dialogObserver = nil
        for subscription in windowSubscriptions { subscription.cancel() }
        windowSubscriptions = []
        firstWindowEvents = nil
    }

    private func send(_ marks: [String]) {
        for name in marks { mark(name) }
    }
}
