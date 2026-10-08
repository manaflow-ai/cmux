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
/// `first_task` (`task`: note, chart),
/// `toggle_project` (`path`), `add_project` (`path`),
/// `theme` (`name`, empty for the Ghostty theme), `detect`,
/// `toggle_profile` (`id`), `toggle_kind` (`kind`), `import`,
/// `cancel_import`, `claim` (`claim`), `allow` (`pane`: accessibility or
/// screenRecording), `dismiss_helper`, `grant` (`pane`, `on`; the mock
/// computer use source only), `gallery` (opens the review tool),
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
        // The close button: leaves the first run unfinished. `skip_all` is Escape.
        case "close": onboarding.controller?.closeWithCloseButton()
        case "skip_all": model.finish(completed: false)
        case "first_task": if let task = params["task"]?.stringValue.flatMap(FirstTask.init(rawValue:)) { model.firstTask.pick(task) }
        case "toggle_project":
            if let path = params["path"]?.stringValue, let project = model.projects.projects.first(where: { $0.id == path }) {
                model.projects.toggle(project)
            }
        case "add_project": if let path = params["path"]?.stringValue { model.projects.add(URL(fileURLWithPath: path, isDirectory: true)) }
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
        result["first_task"] = model.firstTask.task.map { .string($0.rawValue) } ?? .null
        result["first_task_folder"] = .string(model.firstTask.folder.url.path)
        result["first_task_outputs"] = .array(model.firstTask.outputs.map { .string($0.lastPathComponent) })
        result["projects"] = .array(model.projects.projects.map { project in
            .object(["path": .string(project.id), "sessions": .number(Double(project.sessions)),
                     "apps": .array(project.apps.map { .string($0.rawValue) }), "selected": .bool(model.projects.isSelected(project))])
        })
        result["projects_scanning"] = .bool(model.projects.isScanning)
        // Names and ids only: never a chat's title.
        result["classic_workspaces"] = .array(model.classicSessions.workspaces.map { workspace in
            .object(["name": .string(workspace.name), "selected": .bool(model.classicSessions.isSelected(workspace))])
        })
        result["chats"] = .array(model.chats.chats.map { chat in
            .object(["id": .string(chat.id), "selected": .bool(model.chats.isSelected(chat))])
        })
        result["projects_privacy"] = .array(model.projects.privacyFolders.map { .string($0.rawValue) })
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
        let computerUse = model.computerUse
        result["computer_use"] = .object(["accessibility": .bool(computerUse.permissions.accessibility),
                                          "screen_recording": .bool(computerUse.permissions.screenRecording),
                                          "helping": computerUse.helping.map { .string($0.rawValue) } ?? .null])
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
