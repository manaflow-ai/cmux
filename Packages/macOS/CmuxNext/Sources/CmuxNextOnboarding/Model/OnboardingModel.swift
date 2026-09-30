public import CmuxNextDesign
public import Foundation
public import Observation

/// The onboarding flow: five skippable steps and their state. Every step's
/// work is async and cancellable; nothing here blocks the main thread.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: String, CaseIterable, Sendable {
        case welcome, importData, defaultBrowser, defaultTerminal, tour
    }

    public private(set) var step: Step
    /// Direction of the last move, for the slide animation.
    public private(set) var movedForward = true
    public let theme: ThemeStepModel
    public let importer: ImportStepModel
    public let defaults: DefaultAppsStepModel
    public let tour: TourStepModel
    @ObservationIgnored public let services: any OnboardingServices
    /// Set once the flow ended, so a second close does not report twice.
    public private(set) var ended = false
    /// The window asks to close (the controller observes this).
    public var onEnd: ((Bool) -> Void)?

    public init(services: any OnboardingServices, start: Step = .welcome) {
        self.services = services
        step = start
        theme = ThemeStepModel(services: services)
        importer = ImportStepModel(services: services)
        defaults = DefaultAppsStepModel(services: services)
        tour = TourStepModel(services: services)
    }

    public var index: Int { Step.allCases.firstIndex(of: step) ?? 0 }
    public var isFirst: Bool { step == Step.allCases.first }
    public var isLast: Bool { step == Step.allCases.last }

    /// Continue: commits the step's choices, then moves on (or finishes).
    public func next() {
        if step == .welcome { theme.commit() }
        guard !isLast else { return finish(completed: true) }
        go(to: Step.allCases[index + 1])
    }

    public func back() {
        guard !isFirst else { return }
        go(to: Step.allCases[index - 1])
    }

    /// Skip this step: move on without committing it.
    public func skipStep() {
        if step == .welcome { theme.revert() }
        guard !isLast else { return finish(completed: true) }
        go(to: Step.allCases[index + 1])
    }

    public func go(to target: Step) {
        guard target != step else { return }
        movedForward = (Step.allCases.firstIndex(of: target) ?? 0) > index
        step = target
        stepDidAppear()
    }

    /// Starts the step's lazy work (theme files, browser detection, handler state).
    public func stepDidAppear() {
        switch step {
        case .welcome: theme.load()
        case .importData: importer.detect()
        case .defaultBrowser, .defaultTerminal: defaults.refresh()
        case .tour: break
        }
    }

    /// Ends the flow: `completed` false means skipped (Escape, Skip All, close button).
    public func finish(completed: Bool) {
        guard !ended else { return }
        ended = true
        importer.cancel()
        if !completed { theme.revert() }
        services.onboardingDidEnd(completed: completed)
        onEnd?(completed)
    }
}
