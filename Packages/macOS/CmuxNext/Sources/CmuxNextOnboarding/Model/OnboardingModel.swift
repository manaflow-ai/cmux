public import CmuxNextDesign
public import Foundation
public import Observation

/// The onboarding window: a short run of screens, each skippable, each
/// changing something. Work is async and cancellable; nothing here blocks
/// the main thread. The theme applies live; Skip (or closing before
/// Continue) puts the old one back.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: String, CaseIterable, Sendable {
        case firstTask, projects, classicSessions, chats, defaultBrowser, importData, theme, computerUse, accounts
    }

    /// The first run: agent sign-ins, classic cmux workspaces and agent
    /// chats to bring over, then browser import. Done lands on the app.
    static let firstRun: [Step] = [.accounts, .classicSessions, .chats, .importData]
    /// New Tab's Import and Sync: folders to open, then work to bring into them.
    static let bringWork: [Step] = [.projects, .classicSessions, .chats]

    public private(set) var step: Step
    /// The screens of this run: the first run, the group `start` belongs
    /// to, or `start` alone (each only when the App supplies it). A work
    /// screen whose scan found nothing drops out, unless it is up.
    public var steps: [Step] { planned.filter { $0 == step || !foundNothing($0) } }
    private let planned: [Step]
    public let firstTask: FirstTaskStepModel
    public let projects: ProjectsStepModel
    public let classicSessions: ClassicSessionsStepModel
    public let chats: ChatsStepModel
    public let theme: ThemeStepModel
    public let importer: ImportStepModel
    public let defaults: DefaultAppsStepModel
    public let computerUse: ComputerUseStepModel
    @ObservationIgnored public let services: any OnboardingServices
    /// Set once the flow ended, so a second close does not report twice.
    public private(set) var ended = false
    /// The window asks to close (the controller observes this).
    public var onEnd: ((Bool) -> Void)?
    /// This window shows the first run (not a group opened from elsewhere).
    public let isFirstRun: Bool

    /// `resumingFirstRunAt`: the first run, at the step a previous window
    /// (or app launch) left it.
    public init(services: any OnboardingServices, start: Step? = nil, resumingFirstRunAt resume: Step? = nil) {
        self.services = services
        let computerUseSource = services.computerUsePermissions
        func available(_ step: Step) -> Bool {
            switch step {
            // Resumed chats open as agent tabs, as the first task's chat does.
            case .firstTask, .chats: services.canRunFirstTask
            case .classicSessions: services.canImportClassicSessions
            case .accounts: services.hasAccountsStep
            case .computerUse: computerUseSource != nil
            default: true
            }
        }
        let firstRun = Self.firstRun.filter(available)
        // A start the App can't show opens the first run instead.
        let group: [Step]? = resume != nil ? nil : start.flatMap { start in
            guard available(start) else { return nil }
            // The work screens open from New Tab with their own group, not the first run.
            return [Self.bringWork, Self.firstRun].first { $0.contains(start) } ?? [start]
        }
        let steps = group?.filter(available) ?? firstRun
        isFirstRun = group == nil
        planned = steps
        step = (resume ?? start).flatMap { steps.contains($0) ? $0 : nil } ?? steps[0]
        firstTask = FirstTaskStepModel(services: services)
        projects = ProjectsStepModel(services: services)
        classicSessions = ClassicSessionsStepModel(services: services)
        chats = ChatsStepModel(services: services)
        theme = ThemeStepModel(services: services)
        importer = ImportStepModel(services: services)
        defaults = DefaultAppsStepModel(services: services)
        computerUse = ComputerUseStepModel(source: computerUseSource)
        // Opening or resuming only shows the step; it is not the person moving.
        if isFirstRun { services.onboardingDidReach(step, interacted: false) }
    }

    private func foundNothing(_ step: Step) -> Bool {
        switch step {
        case .classicSessions: classicSessions.scanned && classicSessions.workspaces.isEmpty
        case .chats: chats.scanned && chats.chats.isEmpty
        default: false
        }
    }

    public var index: Int { steps.firstIndex(of: step) ?? 0 }
    public var isFirst: Bool { step == steps.first }
    public var isLast: Bool { step == steps.last }

    /// The primary button: Find Browsers on the import step before a person
    /// asked for them, Import while it has a checked choice it has not run,
    /// else Continue (Done on the last step).
    public var primaryTitle: String {
        if step == .importData, importer.phase == .idle { return OnboardingStrings.findBrowsers }
        if step == .importData, importer.canStart { return OnboardingStrings.importButton }
        return isLast ? OnboardingStrings.done : OnboardingStrings.continueButton
    }

    /// The primary button. On the import step with a choice to run it
    /// starts the import and stays, so the rows show it; otherwise it keeps
    /// the step's choice (a running import keeps going in the background)
    /// and moves on or finishes.
    public func next() {
        switch step {
        case .importData where importer.justStarted:
            return
        case .importData where importer.phase == .idle:
            importer.detect()
            return
        case .importData where importer.canStart:
            importer.start()
            return
        case .projects: projects.commit()
        case .classicSessions: classicSessions.commit()
        case .chats: chats.commit()
        case .theme: theme.commit()
        default: break
        }
        guard !isLast else { return finish(completed: true) }
        go(to: steps[index + 1])
    }

    public func back() {
        guard !isFirst else { return }
        go(to: steps[index - 1])
    }

    /// Skip this step: undo what it changed, then move on.
    public func skipStep() {
        if step == .theme { theme.revert() }
        guard !isLast else { return finish(completed: true) }
        go(to: steps[index + 1])
    }

    public func go(to target: Step) {
        guard target != step, steps.contains(target) else { return }
        step = target
        if isFirstRun { services.onboardingDidReach(target, interacted: true) }
        stepDidAppear()
    }

    /// Starts the step's lazy work (handler state, browser detection, theme files).
    public func stepDidAppear() {
        if step != .computerUse { computerUse.stop() }
        // Any screen starts the work scans, so their screens are ready (or gone) by the time they come up.
        if planned.contains(.chats) { chats.scan() }
        if planned.contains(.classicSessions) { classicSessions.scan() }
        switch step {
        case .projects, .classicSessions, .chats: projects.scan()
        case .defaultBrowser: defaults.refresh()
        // Browser detection reads other apps' data: only Find Browsers starts it.
        case .importData: break
        case .theme: theme.load()
        case .firstTask: firstTask.refreshOutputs()
        case .computerUse: computerUse.start()
        case .accounts: break
        }
    }

    /// Ends the flow: `completed` false means skipped (Escape, Skip).
    /// A running import finishes; an uncommitted theme is put back.
    /// The window closed without Skip or Done (close button, quit, the App
    /// rebuilding it): the run is not over. Work stops and an uncommitted
    /// theme is put back, but nothing is recorded as skipped, so the first
    /// run resumes at its step.
    public func leave(notNow: Bool = true) {
        guard !ended else { return }
        ended = true
        if isFirstRun { services.onboardingDidLeave(notNow: notNow) }
        projects.stop()
        chats.stop()
        computerUse.stop()
        if !theme.isCommitted { theme.revert() }
        firstTask.stop()
    }

    public func finish(completed: Bool) {
        guard !ended else { return }
        ended = true
        projects.stop()
        chats.stop()
        computerUse.stop()
        if !completed, !theme.isCommitted { theme.revert() }
        firstTask.stop()
        services.onboardingDidEnd(completed: completed)
        onEnd?(completed)
    }
}
