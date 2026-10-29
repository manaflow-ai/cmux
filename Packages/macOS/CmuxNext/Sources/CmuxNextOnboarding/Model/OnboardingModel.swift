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
        if step == .importData, importer.explainingAccess != nil { return OnboardingStrings.continueTitle }
        if step == .importData, importer.isConfirmingPasswords { return OnboardingStrings.beginImporting }
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
        case .importData where importer.explainingAccess != nil:
            importer.continueAccess()
            return
        // Begin Importing; while Touch ID is up it waits, never ends the window.
        case .importData where importer.isConfirmingPasswords:
            if importer.canStart { importer.start() }
            return
        case .importData where importer.canStart:
            importer.start()
            return
        // Computer Use: Return is the window's one primary action: the next
        // row's Allow, Restart for a helper that did not answer, or Done.
        case .computerUse where !computerUse.allGranted:
            if computerUse.permissions.helperFailed { computerUse.restart() } else { computerUse.allowNext() }
            return
        default:
            finish(completed: true)
        }
    }

    /// The footer's Skip: Skip Importing on the Keychain explainer, where it
    /// leaves without reading anything.
    public var skipTitle: String {
        step == .importData && importer.isConfirmingPasswords ? OnboardingStrings.skipImporting : OnboardingStrings.skip
    }

    /// The footer's Back: shown on the folder and Keychain explainers, off
    /// while the open panel or the Touch ID sheet is up.
    public var canGoBack: Bool {
        guard step == .importData else { return false }
        if importer.explainingAccess != nil { return !importer.requestingAccess }
        return importer.isConfirmingPasswords && !importer.authorizing
    }

    /// Back: from either explainer to the list, nothing read.
    public func goBack() {
        guard canGoBack else { return }
        if importer.explainingAccess != nil { importer.cancelAccess() } else { importer.backFromConsent() }
    }

    /// The bar over the explainers (`ImportStepModel.explainerProgress`); nil elsewhere.
    public var flowProgress: Double? { step == .importData ? importer.explainerProgress : nil }

    /// Skip (Escape): ends the window; a running import finishes. Skip
    /// Importing on the Keychain explainer reads nothing, even when Touch ID
    /// answers after the window is gone.
    public func skipStep() {
        if step == .importData, importer.isConfirmingPasswords { importer.backFromConsent() }
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
