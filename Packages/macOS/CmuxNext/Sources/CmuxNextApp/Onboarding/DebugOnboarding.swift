#if DEBUG
import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings

/// `debug.onboarding` (DEBUG builds): drives the tool window (Import from
/// Browser, Computer Use setup) through its model, the same methods its
/// controls call, so an agent can use it without synthetic input. Returns
/// the state after the action.
///
/// `action`: `open` (`step`: importData, computerUse), `state`, `next`,
/// `skip`, `close`, `skip_all`, `detect`, `toggle_profile` (`id`),
/// `toggle_kind` (`kind`), `import`, `cancel_import`, `toggle_consent`
/// (`id`), `skip_passwords`, `consent_back`, `allow` (`pane`:
/// accessibility or screenRecording), `dismiss_helper`, `grant` (`pane`,
/// `on`; the mock computer use source only).
@MainActor
enum DebugOnboarding {
    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let onboarding = services.onboarding
        let action = params["action"]?.stringValue ?? "state"
        if action == "open" {
            onboarding.show(step: params["step"]?.stringValue.flatMap(OnboardingModel.Step.init(rawValue:)) ?? .importData)
        }
        guard let model = onboarding.controller?.model else { return state(onboarding) }
        // Only a person passes the password consent screen.
        if case .confirmingPasswords = model.importer.phase, action == "next" || action == "import" { return state(onboarding) }
        switch action {
        case "next": model.next()
        case "skip": model.skipStep()
        // The close button. `skip_all` is Escape.
        case "close": onboarding.controller?.closeWithCloseButton()
        case "skip_all": model.finish(completed: false)
        case "detect": model.importer.redetect()
        case "toggle_profile":
            if let id = params["id"]?.stringValue, let profile = model.importer.profiles.first(where: { $0.id == id }) {
                model.importer.toggle(profile)
            }
        case "toggle_kind": if let kind = params["kind"]?.stringValue.flatMap(ImportDataKind.init(rawValue:)) { model.importer.toggle(kind) }
        case "import": model.importer.start()
        case "cancel_import": model.importer.cancel()
        case "toggle_consent":
            if let id = params["id"]?.stringValue, let profile = model.importer.passwordProfiles.first(where: { $0.id == id }) {
                model.importer.toggleConsent(profile)
            }
        case "skip_passwords": model.importer.skipPasswords()
        case "consent_back": model.importer.backFromConsent()
        case "allow": if let pane = params["pane"]?.stringValue.flatMap(ComputerUsePermissionPane.init(rawValue:)) { model.computerUse.allow(pane) }
        case "dismiss_helper": model.computerUse.dismissHelper()
        case "grant":
            if let pane = params["pane"]?.stringValue.flatMap(ComputerUsePermissionPane.init(rawValue:)),
               let mock = model.services.computerUsePermissions as? MockComputerUsePermissionSource {
                let on = params["on"]?.boolValue ?? true
                switch pane {
                case .accessibility: mock.current.accessibility = on
                case .screenRecording: mock.current.screenRecording = on
                }
            }
        default: break
        }
        return state(onboarding)
    }

    static func state(_ onboarding: OnboardingService) -> JSONValue {
        var result: [String: JSONValue] = ["open": .bool(onboarding.controller != nil)]
        if let recording = onboarding.defaultApps as? RecordingDefaultApps {
            result["default_apps_mock"] = .array(recording.log.map(JSONValue.string))
        }
        guard let controller = onboarding.controller else { return .object(result) }
        let model = controller.model
        result["window"] = .number(Double(controller.window?.windowNumber ?? 0))
        result["key"] = .bool(controller.window?.isKeyWindow ?? false)
        result["step"] = .string(model.step.rawValue)
        result["steps"] = .array(model.steps.map { .string($0.rawValue) })
        result["import_phase"] = .string(phaseName(model.importer.phase))
        result["profiles"] = .array(model.importer.profiles.map { profile in
            .object(["id": .string(profile.id), "selected": .bool(model.importer.isSelected(profile)),
                     "kinds": .array(profile.importableKinds.map { .string($0.rawValue) })])
        })
        result["kinds"] = .array(model.importer.kinds.map(\.rawValue).sorted().map(JSONValue.string))
        result["merge_target"] = model.importer.mergeTarget.map(JSONValue.string) ?? .null
        if case .finished(let summary) = model.importer.phase {
            let counts = summary.counts
            result["counts"] = .object(["bookmarks": JSONValue(counts.bookmarks), "history": JSONValue(counts.history),
                                        "cookies": JSONValue(counts.cookies), "passwords": JSONValue(counts.passwords)])
            // Counts and reasons only: never a site, a username or a value.
            result["password_issues"] = .object(Dictionary(uniqueKeysWithValues: summary.batches.compactMap { batch in
                batch.passwordError.map { (batch.source.sourceKey, JSONValue.string(String(describing: $0))) }
            }))
            result["cookie_issues"] = .object(Dictionary(uniqueKeysWithValues: summary.batches.compactMap { batch in
                batch.cookieError.map { (batch.source.sourceKey, JSONValue.string(String(describing: $0))) }
            }))
            result["targets"] = .object(Dictionary(uniqueKeysWithValues: summary.batches.map { ($0.source.sourceKey, JSONValue.string($0.source.targetProfileID)) }))
            result["failures"] = .object(summary.failures.mapValues(JSONValue.string))
        }
        let computerUse = model.computerUse
        result["computer_use"] = .object(["accessibility": .bool(computerUse.permissions.accessibility),
                                          "screen_recording": .bool(computerUse.permissions.screenRecording),
                                          "helping": computerUse.helping.map { .string($0.rawValue) } ?? .null])
        return .object(result)
    }

    private static func phaseName(_ phase: ImportStepModel.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .detecting: "detecting"
        case .ready: "ready"
        case .confirmingPasswords: "confirming_passwords"
        case .importing: "importing"
        case .finished: "finished"
        case .cancelled: "cancelled"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}
#endif
