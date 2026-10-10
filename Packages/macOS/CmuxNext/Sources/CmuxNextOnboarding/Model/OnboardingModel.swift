public import CmuxNextDesign
public import Foundation
public import Observation

/// The tool window: one screen for one tool, Import from Browser or
/// Computer Use setup (Lawrence 2026-10-09: no onboarding window, no
/// sequence). Work is async and cancellable; nothing here blocks the main
/// thread.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: String, CaseIterable, Sendable {
        case importData, computerUse
    }

    /// The tool this window shows; it never changes.
    public let step: Step
    /// The screens of this window: only `step`.
    public var steps: [Step] { [step] }
    public let importer: ImportStepModel
    public let computerUse: ComputerUseStepModel
    @ObservationIgnored public let services: any OnboardingServices
    /// Set once the window ended, so a second close does not report twice.
    public private(set) var ended = false
    /// The window asks to close (the controller observes this).
    public var onEnd: ((Bool) -> Void)?

    public init(services: any OnboardingServices, step: Step) {
        self.services = services
        self.step = step
        importer = ImportStepModel(services: services)
        computerUse = ComputerUseStepModel(source: services.computerUsePermissions)
    }

    /// The primary button: Find Browsers on the import step before a person
    /// asked for them, Import while it has a checked choice it has not run,
    /// else Done.
    public var primaryTitle: String {
        if step == .importData, importer.phase == .idle { return OnboardingStrings.findBrowsers }
        if step == .importData, importer.canStart { return OnboardingStrings.importButton }
        return OnboardingStrings.done
    }

    /// The primary button. On the import step with a choice to run it
    /// starts the import and stays, so the rows show it; otherwise it ends
    /// the window (a running import keeps going in the background).
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
        default:
            finish(completed: true)
        }
    }

    /// Skip (Escape): ends the window; a running import finishes.
    public func skipStep() {
        finish(completed: false)
    }

    /// Starts the step's lazy work. Browser detection reads other apps'
    /// data: only Find Browsers starts it.
    public func stepDidAppear() {
        if step == .computerUse { computerUse.start() }
    }

    /// The window closed without Skip or Done (the close button, quit):
    /// work stops.
    public func leave() {
        guard !ended else { return }
        ended = true
        computerUse.stop()
    }

    public func finish(completed: Bool) {
        guard !ended else { return }
        ended = true
        computerUse.stop()
        onEnd?(completed)
    }
}
