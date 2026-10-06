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

    /// The first run: agent sign-ins, then browser import. Done lands on the app.
    static let firstRun: [Step] = [.accounts, .importData]
    /// New Tab's Import and Sync: folders to open, then work to bring into them.
    static let bringWork: [Step] = [.projects, .classicSessions, .chats]

    public private(set) var step: Step
    /// The screens of this run: the first run, the group `start` belongs
    /// to, or `start` alone (each only when the App supplies it).
    public let steps: [Step]
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

    public init(services: any OnboardingServices, start: Step? = nil) {
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
        let group: [Step]? = start.flatMap { start in
            guard available(start) else { return nil }
            return [Self.firstRun, Self.bringWork].first { $0.contains(start) } ?? [start]
        }
        let steps = group?.filter(available) ?? firstRun
        self.steps = steps
        step = start.flatMap { steps.contains($0) ? $0 : nil } ?? steps[0]
        firstTask = FirstTaskStepModel(services: services)
        projects = ProjectsStepModel(services: services)
        classicSessions = ClassicSessionsStepModel(services: services)
        chats = ChatsStepModel(services: services)
        theme = ThemeStepModel(services: services)
        importer = ImportStepModel(services: services)
        defaults = DefaultAppsStepModel(services: services)
        computerUse = ComputerUseStepModel(source: computerUseSource)
    }

    public var index: Int { steps.firstIndex(of: step) ?? 0 }
    public var isFirst: Bool { step == steps.first }
    public var isLast: Bool { step == steps.last }

    /// The primary button: Import while the import step has a checked
    /// choice it has not run, else Continue (Done on the last step).
    public var primaryTitle: String {
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
        stepDidAppear()
    }

    /// Starts the step's lazy work (handler state, browser detection, theme files).
    public func stepDidAppear() {
        if step != .computerUse { computerUse.stop() }
        switch step {
        // Any of these screens starts every scan, so the next one's list is ready.
        case .projects, .classicSessions, .chats:
            projects.scan()
            if steps.contains(.chats) { chats.scan() }
            if steps.contains(.classicSessions) { classicSessions.scan() }
        case .defaultBrowser: defaults.refresh()
        case .importData: importer.detect()
        case .theme: theme.load()
        case .firstTask: firstTask.refreshOutputs()
        case .computerUse: computerUse.start()
        case .accounts: break
        }
    }

    /// Ends the flow: `completed` false means skipped (Escape, close button).
    /// A running import finishes; an uncommitted theme is put back.
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
