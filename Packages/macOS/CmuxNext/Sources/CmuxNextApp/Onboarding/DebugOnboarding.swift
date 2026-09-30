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
/// `theme` (`name`, empty for the Ghostty theme), `density` (`value`),
/// `detect`, `toggle_profile` (`id`), `toggle_kind` (`kind`), `import`,
/// `cancel_import`, `reset_import`, `open_tabs`, `install` (`id`),
/// `claim` (`claim`), `claim_terminal`, `tour` (`page`).
@MainActor
enum DebugOnboarding {
    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let onboarding = services.onboarding
        let action = params["action"]?.stringValue ?? "state"
        if action == "open" {
            onboarding.show(step: params["step"]?.stringValue.flatMap(OnboardingModel.Step.init(rawValue:)) ?? .welcome)
        }
        guard let model = onboarding.controller?.model else { return state(onboarding) }
        switch action {
        case "next": model.next()
        case "back": model.back()
        case "skip": model.skipStep()
        case "close": model.finish(completed: false)
        case "theme": model.theme.select(params["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        case "density": model.theme.setDensity(params["value"]?.stringValue == "comfortable" ? .comfortable : .compact)
        case "detect": model.importer.redetect()
        case "toggle_profile":
            if let id = params["id"]?.stringValue, let profile = model.importer.sources.flatMap(\.profiles).first(where: { $0.id == id }) {
                model.importer.toggle(profile)
            }
        case "toggle_kind": if let kind = params["kind"]?.stringValue.flatMap(ImportDataKind.init(rawValue:)) { model.importer.toggle(kind) }
        case "import": model.importer.start()
        case "cancel_import": model.importer.cancel()
        case "reset_import": model.importer.reset()
        case "open_tabs": model.importer.openImportedTabs()
        case "install":
            if case .finished(let summary) = model.importer.phase, let item = summary.extensions.first(where: { $0.id == params["id"]?.stringValue }) {
                model.importer.install(item)
            }
        case "claim": if let claim = params["claim"]?.stringValue.flatMap(DefaultHandlerClaim.init(rawValue:)) { model.defaults.request(claim) }
        case "claim_terminal": model.defaults.requestAllTerminalClaims()
        case "tour": model.tour.show(params["page"]?.doubleValue.map { Int($0) } ?? 0)
        default: break
        }
        return state(onboarding)
    }

    static func state(_ onboarding: OnboardingService) -> JSONValue {
        var result: [String: JSONValue] = ["open": .bool(onboarding.controller != nil)]
        if let recording = onboarding.defaultApps as? RecordingDefaultApps {
            result["default_apps_mock"] = .array(recording.log.map(JSONValue.string))
        }
        guard let controller = onboarding.controller, let model = Optional(controller.model) else { return .object(result) }
        result["window"] = .number(Double(controller.window?.windowNumber ?? 0))
        result["key"] = .bool(controller.window?.isKeyWindow ?? false)
        result["step"] = .string(model.step.rawValue)
        result["theme"] = model.theme.selected.map(JSONValue.string) ?? .null
        result["themes"] = .array(model.theme.choices.map { .string($0.name ?? "") })
        result["density"] = .string(model.theme.density.rawValue)
        result["import_phase"] = .string(phaseName(model.importer.phase))
        result["sources"] = .array(model.importer.sources.map { source in
            .object([
                "browser": .string(source.browser.rawValue),
                "full_disk_access": .bool(source.needsFullDiskAccess),
                "profiles": .array(source.profiles.map { profile in
                    .object(["id": .string(profile.id), "name": .string(profile.displayName),
                             "kinds": .array(profile.importableKinds.map { .string($0.rawValue) })])
                }),
            ])
        })
        result["selected"] = .array(model.importer.selectedProfiles.sorted().map(JSONValue.string))
        result["kinds"] = .array(model.importer.kinds.map(\.rawValue).sorted().map(JSONValue.string))
        if case .finished(let summary) = model.importer.phase {
            let counts = summary.counts
            result["counts"] = .object(["bookmarks": JSONValue(counts.bookmarks), "history": JSONValue(counts.history),
                                        "open_tabs": JSONValue(counts.openTabs), "extensions": JSONValue(counts.extensions)])
            result["extensions"] = .array(summary.extensions.map { .object(["id": .string($0.id), "name": .string($0.name)]) })
            result["failures"] = .object(summary.failures.mapValues(JSONValue.string))
        }
        result["claimed"] = .array(model.defaults.claimed.map(\.rawValue).sorted().map(JSONValue.string))
        result["tour_page"] = JSONValue(model.tour.page)
        return .object(result)
    }

    private static func phaseName(_ phase: ImportStepModel.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .detecting: "detecting"
        case .ready: "ready"
        case .importing: "importing"
        case .finished: "finished"
        case .cancelled: "cancelled"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}
#endif
