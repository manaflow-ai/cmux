public import CmuxNextWakeups
public import Foundation

/// The app's main-thread scheduling, as an agent pane uses it (plans/cmux-next/chrome-parity/p06-scheduler.md,
/// "Posting API"): the one deadline scheduler, and through it the one ``MainWorkScheduler`` its posts go on, and
/// the app's notice fan-outs. The composition root hands the app's own to the agent tabs once
/// (`AgentTabStore.wired(to:)`), and each pane takes it from there, so no pane makes a scheduler, a timer or an
/// observer of its own. Chromium's views take the browser UI thread's typed task runners the same way, from their
/// owner (content/browser/scheduler/browser_task_queues.h), never through a global.
///
/// ```swift
/// let mainThread = AgentPaneMainThread(deadlines: services.mainDeadlines, appEvents: services.appEvents,
///                                      workspaceEvents: services.workspaceEvents)
/// let view = AgentPaneView(mainThread: mainThread, model: model, work: work, webUI: webUI, gestures: gestures)
/// ```
public struct AgentPaneMainThread {
    /// The app's one `MainDeadline` placer (`AppServices.mainDeadlines`).
    public let deadlines: MainDeadlineScheduler
    /// The app's notices from `NotificationCenter.default` (`AppServices.appEvents`).
    public let appEvents: AppEvents
    /// The app's notices from the workspace center: sleep and wake (`AppServices.workspaceEvents`).
    public let workspaceEvents: AppEvents

    /// The app's one main-thread scheduler, the one the deadlines post on.
    public var mainWork: MainWorkScheduler { deadlines.work }

    public init(deadlines: MainDeadlineScheduler, appEvents: AppEvents, workspaceEvents: AppEvents) {
        self.deadlines = deadlines
        self.appEvents = appEvents
        self.workspaceEvents = workspaceEvents
    }

    /// Scheduling for panes outside the app (tests, a store made without the composition root): deadlines on
    /// `mainWork`, and notices from centers of their own, which only their maker posts to.
    public static func standalone(on mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget())) -> AgentPaneMainThread {
        AgentPaneMainThread(deadlines: MainDeadlineScheduler(work: mainWork), appEvents: AppEvents(center: NotificationCenter()),
                            workspaceEvents: AppEvents(center: NotificationCenter()))
    }
}
