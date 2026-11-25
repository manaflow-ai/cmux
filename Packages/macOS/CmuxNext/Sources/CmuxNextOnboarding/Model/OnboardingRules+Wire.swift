import CmuxNextBrowserImport
import CmuxNextWindowRules

/// What the Rust onboarding rules read and answer (`onboarding_*`, cmux-window-rules `onboarding`):
/// the window's facts out, the footer and the Import step's selection rules back. No rule lives here.
enum OnboardingRules {
    struct ImportFacts: Encodable {
        var phase: String
        var justStarted = false, hasPlan = false, requestingAccess = false, authorizing = false
        var authorizationDenied = false, exportOnlyPasswords = false, passwordError = false
    }

    struct Window: Encodable {
        struct ComputerUse: Encodable { var allGranted: Bool, helperFailed: Bool }
        var step: String
        var `import`: ImportFacts
        var computerUse: ComputerUse
    }

    struct Footer: Decodable {
        var primaryTitle: String
        var primary: String
        var skipImporting: Bool
        var back: String?
        var canAdvance: Bool
        var flowProgress: Double?
        var skipLeavesConsent: Bool
        var skipRevertsChoices: Bool
    }

    struct Import: Decodable {
        var canEditSelection: Bool, canStart: Bool, offersPasswordCsv: Bool
        var explainerProgress: Double?
    }

    struct Kinds: Decodable {
        var choices: [ImportDataKind], defaults: [ImportDataKind], preset: [ImportDataKind]
    }

    private struct KindsRequest: Encodable { var passwordStore: Bool, preset: [ImportDataKind] }
    private struct BrowsersRequest: Encodable { var browsers: [String] }
    private struct Order: Decodable { var order: [Int] }

    /// The footer of `window`; the idle one (Done, nothing to run) when Rust does not answer.
    static func footer(_ window: Window) -> Footer {
        WindowRules().call("onboarding_footer", window, as: Footer.self)
            ?? Footer(primaryTitle: "done", primary: "finish", skipImporting: false, back: nil, canAdvance: true,
                      flowProgress: nil, skipLeavesConsent: false, skipRevertsChoices: false)
    }

    static func importRules(_ facts: ImportFacts) -> Import {
        WindowRules().call("onboarding_import", facts, as: Import.self)
            ?? Import(canEditSelection: false, canStart: false, offersPasswordCsv: false, explainerProgress: nil)
    }

    static func kinds(passwordStore: Bool, preset: [ImportDataKind] = []) -> Kinds {
        WindowRules().call("onboarding_kinds", KindsRequest(passwordStore: passwordStore, preset: preset), as: Kinds.self)
            ?? Kinds(choices: [], defaults: [], preset: [])
    }

    /// `sources` in list order, Edge first.
    static func edgeFirst(_ sources: [BrowserSource]) -> [BrowserSource] {
        let request = BrowsersRequest(browsers: sources.map(\.browser.rawValue))
        guard let order = WindowRules().call("onboarding_edge_first", request, as: Order.self)?.order,
              order.count == sources.count else { return sources }
        return order.map { sources[$0] }
    }
}

extension ImportStepModel.Phase {
    /// The phase's name on the wire (`ImportPhase`), without its payload.
    var wire: String {
        switch self {
        case .idle: "idle"
        case .detecting: "detecting"
        case .ready: "ready"
        case .explainingAccess: "explainingAccess"
        case .confirmingPasswords: "confirmingPasswords"
        case .importing: "importing"
        case .finished: "finished"
        case .cancelled: "cancelled"
        case .failed: "failed"
        }
    }
}

extension ImportStepModel {
    /// The step's facts for the rules.
    var facts: OnboardingRules.ImportFacts {
        let exportOnly = profiles.contains {
            if case .unsupported = $0.availability(of: .passwords) { true } else { false }
        }
        var facts = OnboardingRules.ImportFacts(phase: phase.wire)
        facts.justStarted = justStarted
        facts.hasPlan = !plan.items.isEmpty
        facts.requestingAccess = requestingAccess
        facts.authorizing = authorizing
        facts.authorizationDenied = authorizationDenied
        facts.exportOnlyPasswords = exportOnly
        facts.passwordError = summary?.batches.contains { $0.passwordError != nil } ?? false
        return facts
    }
}

extension OnboardingModel {
    /// The window's footer, from Rust.
    var footer: OnboardingRules.Footer {
        OnboardingRules.footer(OnboardingRules.Window(
            step: step.rawValue, import: importer.facts,
            computerUse: .init(allGranted: computerUse.allGranted, helperFailed: computerUse.permissions.helperFailed)))
    }
}
