public import CmuxNextDesign
public import Foundation
public import Observation

/// The onboarding flow: one decision per step, each skippable. Work is
/// async and cancellable; nothing here blocks the main thread. The theme
/// applies live; Skip (or closing before Continue) puts the old one back.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: String, CaseIterable, Sendable {
        case role, firstTask, projects, classicSessions, chats, defaultBrowser, importData, theme, computerUse, accounts
    }

    public private(set) var step: Step
    /// The steps of this flow (`firstTask`, `chats` and `accounts` only when the App supplies them).
    public let steps: [Step]
    public let role: RoleStepModel
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
        let steps = Step.allCases.filter { step in
            switch step {
            // Resumed chats open as agent tabs, as the first task's chat does.
            case .firstTask, .chats: services.canRunFirstTask
            case .classicSessions: services.canImportClassicSessions
            case .accounts: services.hasAccountsStep
            case .computerUse: computerUseSource != nil
            default: true
            }
        }
        self.steps = steps
        step = start.flatMap { steps.contains($0) ? $0 : nil } ?? steps[0]
        role = RoleStepModel(services: services)
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
        case .role: role.commit()
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
        // The role step starts the project and chat scans, so their lists are ready.
        case .role, .projects, .classicSessions, .chats:
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
