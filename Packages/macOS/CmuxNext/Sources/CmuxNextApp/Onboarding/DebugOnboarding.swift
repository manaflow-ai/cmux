#if DEBUG
import AppKit
import CmuxNextBrowserImport
import CmuxNextDesign
import CmuxNextOnboarding
import CmuxNextSettings

/// `debug.onboarding` (DEBUG builds): drives the onboarding window through
/// its model, the same methods its controls call, so an agent can walk
/// every step without synthetic input. Returns the state after the action.
///
/// `action`: `open` (`step`), `state`, `next`, `back`, `skip`, `close`,
/// `role` (`role`), `describe` (`text`), `suggest_tasks` (`on`),
/// `first_task` (`task`: note, chart),
/// `theme` (`name`, empty for the Ghostty theme), `detect`,
/// `toggle_profile` (`id`), `toggle_kind` (`kind`), `import`,
/// `cancel_import`, `claim` (`claim`), `gallery` (opens the review tool),
/// `gallery_key` (`key`: left, right, up, down, 1-9, p, space, t, return,
/// copy, escape), `gallery_state`.
@MainActor
enum DebugOnboarding {
    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let onboarding = services.onboarding
        let action = params["action"]?.stringValue ?? "state"
        if action == "open" {
            onboarding.show(step: params["step"]?.stringValue.flatMap(OnboardingModel.Step.init(rawValue:)))
        }
        if let result = gallery(action, params, onboarding) { return result }
        guard let model = onboarding.controller?.model else { return state(onboarding) }
        // Only a person passes the password consent screen.
        if case .confirmingPasswords = model.importer.phase, action == "next" || action == "import" { return state(onboarding) }
        switch action {
        case "next": model.next()
        case "back": model.back()
        case "skip": model.skipStep()
        case "close": model.finish(completed: false)
        case "role": if let role = params["role"]?.stringValue.flatMap(OnboardingRole.init(rawValue:)) { model.role.select(role) }
        case "describe": model.role.describe(params["text"]?.stringValue ?? "")
        case "first_task": if let task = params["task"]?.stringValue.flatMap(FirstTask.init(rawValue:)) { model.firstTask.pick(task) }
        case "suggest_tasks": model.role.suggestTasks = params["on"]?.boolValue ?? !model.role.suggestTasks
        case "theme": model.theme.select(params["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
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
        case "claim": if let claim = params["claim"]?.stringValue.flatMap(DefaultHandlerClaim.init(rawValue:)) { model.defaults.request(claim) }
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
        result["role"] = model.role.role.map { .string($0.rawValue) } ?? .null
        result["other_role"] = .string(model.role.otherRole)
        result["suggest_tasks"] = .bool(model.role.suggestTasks)
        result["saved_profile"] = onboarding.profile.map { profile in
            .object(["role": profile.role.map { .string($0.rawValue) } ?? .null, "other_role": profile.otherRole.map(JSONValue.string) ?? .null,
                     "suggest_tasks": .bool(profile.suggestTasks)])
        } ?? .null
        result["first_task"] = model.firstTask.task.map { .string($0.rawValue) } ?? .null
        result["first_task_folder"] = .string(model.firstTask.folder.url.path)
        result["first_task_outputs"] = .array(model.firstTask.outputs.map { .string($0.lastPathComponent) })
        result["theme"] = model.theme.selected.map(JSONValue.string) ?? .null
        result["themes"] = .array(model.theme.choices.map { .string($0.name ?? "") })
        result["import_phase"] = .string(phaseName(model.importer.phase))
        result["profiles"] = .array(model.importer.profiles.map { profile in
            .object(["id": .string(profile.id), "selected": .bool(model.importer.isSelected(profile)),
                     "kinds": .array(profile.importableKinds.map { .string($0.rawValue) })])
        })
        result["kinds"] = .array(model.importer.kinds.map(\.rawValue).sorted().map(JSONValue.string))
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
        result["claimed"] = .array(model.defaults.claimed.map(\.rawValue).sorted().map(JSONValue.string))
        return .object(result)
    }

    /// Gallery actions; nil when `action` is not one.
    private static func gallery(_ action: String, _ params: [String: JSONValue], _ onboarding: OnboardingService) -> JSONValue? {
        switch action {
        case "gallery": onboarding.showGallery()
        case "gallery_key":
            if let key = params["key"]?.stringValue.flatMap(GalleryKey.init(name:)) { onboarding.gallery?.handle(key) }
        case "gallery_state": break
        default: return nil
        }
        let store = onboarding.galleryStore
        return .object([
            "gallery_window": .number(Double(onboarding.gallery?.window?.windowNumber ?? 0)),
            "file": .string(store.url.path),
            "step": .string(store.review.step),
            "index": .number(Double(store.review.index)),
            "summary": .string(GalleryReviewStore.summary(store.review)),
            "variants": .object(Dictionary(uniqueKeysWithValues: OnboardingModel.Step.allCases.map { step in
                (step.rawValue, JSONValue.array(step.variants.map { .string($0.id) }))
            })),
        ])
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
