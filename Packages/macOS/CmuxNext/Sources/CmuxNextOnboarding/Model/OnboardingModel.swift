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
        case defaultBrowser, importData, theme, accounts
    }

    public private(set) var step: Step
    /// The steps of this flow (`accounts` only when the App supplies it).
    public let steps: [Step]
    public let theme: ThemeStepModel
    public let importer: ImportStepModel
    public let defaults: DefaultAppsStepModel
    @ObservationIgnored public let services: any OnboardingServices
    /// Set once the flow ended, so a second close does not report twice.
    public private(set) var ended = false
    /// The window asks to close (the controller observes this).
    public var onEnd: ((Bool) -> Void)?

    public init(services: any OnboardingServices, start: Step? = nil) {
        self.services = services
        let steps = Step.allCases.filter { $0 != .accounts || services.hasAccountsStep }
        self.steps = steps
        step = start.flatMap { steps.contains($0) ? $0 : nil } ?? steps[0]
        theme = ThemeStepModel(services: services)
        importer = ImportStepModel(services: services)
        defaults = DefaultAppsStepModel(services: services)
    }

    public var index: Int { steps.firstIndex(of: step) ?? 0 }
    public var isFirst: Bool { step == steps.first }
    public var isLast: Bool { step == steps.last }

    /// Continue: keeps the step's choice (the import starts here and keeps
    /// running in the background), then moves on or finishes.
    public func next() {
        switch step {
        case .importData: importer.start()
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
        switch step {
        case .defaultBrowser: defaults.refresh()
        case .importData: importer.detect()
        case .theme: theme.load()
        case .accounts: break
        }
    }

    /// Ends the flow: `completed` false means skipped (Escape, close button).
    /// A running import finishes; an uncommitted theme is put back.
    public func finish(completed: Bool) {
        guard !ended else { return }
        ended = true
        if !completed, !theme.isCommitted { theme.revert() }
        services.onboardingDidEnd(completed: completed)
        onEnd?(completed)
    }
}
