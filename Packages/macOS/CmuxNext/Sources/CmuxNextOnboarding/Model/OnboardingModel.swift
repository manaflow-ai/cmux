public import CmuxNextAgentIntegrations
public import CmuxNextDesign
public import Foundation
public import Observation

/// The tool window: one screen for one tool, Agents (first run), Import
/// from Browser or Computer Use setup (Lawrence 2026-10-09: no onboarding
/// window, no sequence). Work is async and cancellable; nothing here blocks the main
/// thread.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: String, CaseIterable, Sendable {
        // Agents comes first at a first run. importData is the browser importer (Import from Browser).
        // makeItYours: a new person's one setup screen (how they work, density, background), cmux#48416.
        case agents, importData, computerUse, makeItYours
    }

    /// The tool this window shows; it never changes.
    public let step: Step
    /// The screens of this window: only `step`.
    public var steps: [Step] { [step] }
    public let importer: ImportStepModel
    public let computerUse: ComputerUseStepModel
    public let agents: AgentsStepModel
    public let makeItYours: MakeItYoursStepModel
    @ObservationIgnored public let services: any OnboardingServices
    /// Set once the window ended, so a second close does not report twice.
    public private(set) var ended = false
    /// The window asks to close (the controller observes this).
    public var onEnd: ((Bool) -> Void)?

    /// `choices`: Make cmux Yours' source, else the services' own. `clock` times the Computer Use done
    /// view's close (tests pass their own).
    public init(services: any OnboardingServices, step: Step, choices: (any FirstRunChoicesSource)? = nil,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.services = services
        self.step = step
        importer = ImportStepModel(services: services)
        computerUse = ComputerUseStepModel(source: services.computerUsePermissions, clock: clock)
        agents = AgentsStepModel(source: services.agentSignIns)
        makeItYours = MakeItYoursStepModel(source: choices ?? services.firstRunChoices)
        // The done view's time is up: the window closes as Done.
        computerUse.onFinished = { [weak self] in self?.finish(completed: true) }
    }

    /// The primary button's title: Rust names it (`footer.primaryTitle`), the app localizes it.
    public var primaryTitle: String {
        switch footer.primaryTitle {
        case "detecting": OnboardingStrings.detecting
        case "findBrowsers": OnboardingStrings.findBrowsers
        case "continue": OnboardingStrings.continueTitle
        case "beginImporting": OnboardingStrings.beginImporting
        case "import": OnboardingStrings.importButton
        default: OnboardingStrings.done
        }
    }

    /// The primary button: Rust says what it does, this runs it.
    public func next() {
        switch footer.primary {
        case "none": return
        case "detect": importer.detect()
        case "continueAccess": importer.continueAccess()
        case "startImport": importer.start()
        case "restartHelper": computerUse.restart()
        case "allowNext": computerUse.allowNext()
        default: finish(completed: true)
        }
    }

    /// The footer's Skip: Skip Importing on the Keychain explainer, where it
    /// leaves without reading anything.
    public var skipTitle: String { footer.skipImporting ? OnboardingStrings.skipImporting : OnboardingStrings.skip }

    /// The footer's Back: shown on the folder and Keychain explainers, off
    /// while the open panel or the Touch ID sheet is up.
    public var canGoBack: Bool { footer.back != nil }

    /// Whether the footer's primary action can run now.
    public var canAdvance: Bool { footer.canAdvance }

    /// Back: from either explainer to the list, nothing read.
    public func goBack() {
        switch footer.back {
        case "cancelAccess": importer.cancelAccess()
        case "backFromConsent": importer.backFromConsent()
        default: return
        }
    }

    /// The bar over the explainers; nil elsewhere.
    public var flowProgress: Double? { footer.flowProgress }

    /// Skip (Escape): ends the window; a running import finishes.
    public func skipStep() {
        let footer = footer
        if footer.skipLeavesConsent { importer.backFromConsent() }
        // Make cmux Yours' Skip keeps the person's settings: the picks it made live are put back.
        if footer.skipRevertsChoices { makeItYours.revert() }
        finish(completed: false)
    }

    /// Starts the step's work. Opening Import from Browser is already an
    /// explicit request, so browser detection can begin immediately; the
    /// privacy prompt (when macOS needs one) still remains under the person's
    /// control.
    public func stepDidAppear() {
        switch step {
        case .importData: importer.detect()
        case .computerUse: computerUse.start()
        case .agents: agents.start()
        case .makeItYours: makeItYours.start()
        }
    }

    /// The window became key: back from an agent's sign-in, the Agents step reads again.
    public func windowBecameKey() {
        if step == .agents { agents.cameBack() }
    }

    /// The window closed without Skip or Done (the close button, quit):
    /// work stops.
    public func leave() {
        guard !ended else { return }
        ended = true
        computerUse.stop()
        importer.stopDetecting()
        agents.stop()
        makeItYours.stop()
    }

    public func finish(completed: Bool) {
        guard !ended else { return }
        ended = true
        computerUse.stop()
        importer.stopDetecting()
        agents.stop()
        makeItYours.stop()
        onEnd?(completed)
    }
}
