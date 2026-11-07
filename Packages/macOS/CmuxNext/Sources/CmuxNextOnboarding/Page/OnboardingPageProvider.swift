import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Serves the onboarding page from the window's ``OnboardingModel``: `cmux.onboarding.state`, the
/// `cmux.onboarding.changed` stream (the whole state after each model or icon change, coalesced,
/// only when it differs), and the gestures, each a model call. Like the AppKit controls it replaces
/// and the app's other bundled pages (Settings, Passwords), a gesture needs no key or mouse event:
/// VoiceOver presses a control without one. The window loads only this bundled page under the
/// strict CSP, and every op is a step the person could take in the window anyway; the native
/// prompts behind them (the folder open panel, Touch ID, System Settings) still ask the person.
@MainActor
final class OnboardingPageProvider: PageProvider {
    private let model: OnboardingModel
    private let images = OnboardingPageImages()

    init(model: OnboardingModel) {
        self.model = model
    }

    var state: OnboardingPageState { OnboardingPageState(model: model, images: images) }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        if op == "cmux.onboarding.state" { return try Self.json(state) }
        try perform(op, params)
        return [:]
    }

    /// One gesture on the model. Unknown ids and kinds are refused; a gesture the model does not
    /// take now (a toggle during an import) is the model's no-op.
    func perform(_ op: String, _ params: JSONValue) throws {
        let importer = model.importer
        switch op {
        case "cmux.onboarding.next": model.next()
        case "cmux.onboarding.skip": model.skipStep()
        case "cmux.onboarding.back": model.goBack()
        case "cmux.onboarding.agents.signIn": model.agents.signIn(try Self.string(params, "id"))
        case "cmux.onboarding.import.toggleProfile": importer.toggle(try profile(params))
        case "cmux.onboarding.import.toggleKind":
            guard let kind = ImportDataKind(rawValue: try Self.string(params, "kind")) else { throw PageError.invalidParams("unknown kind") }
            importer.toggle(kind)
        case "cmux.onboarding.import.toggleKeepInSync": importer.toggleKeepInSync()
        case "cmux.onboarding.import.setTarget": importer.setTarget(params["target"]?.stringValue, for: try profile(params))
        case "cmux.onboarding.import.askAccess":
            let raw = try Self.string(params, "browser")
            guard let browser = importer.awaitingAccess.first(where: { $0.rawValue == raw }) else {
                throw PageError.invalidParams("unknown browser")
            }
            importer.askAccess(browser)
        case "cmux.onboarding.import.openFullDiskAccess": importer.openFullDiskAccessSettings()
        case "cmux.onboarding.import.fromFiles": importer.importFromFiles()
        case "cmux.onboarding.import.passwordsCSV": importer.importPasswordsFromCSV()
        case "cmux.onboarding.import.skipPasswords": importer.skipPasswords()
        case "cmux.onboarding.computerUse.allow":
            guard let pane = ComputerUsePermissionPane(rawValue: try Self.string(params, "pane")) else {
                throw PageError.invalidParams("unknown pane")
            }
            model.computerUse.allow(pane)
        case "cmux.onboarding.computerUse.restart": model.computerUse.restart()
        default: throw PageError.unknownOp(op)
        }
    }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == "cmux.onboarding.changed" else { throw PageError.unknownOp(stream) }
        // task-owner: one per page subscription, following the model and the icons; its PageSubscription cancels it.
        let task = Task { [weak self] in
            for await state in ObservationStream({ [weak self] in self?.state }) {
                guard !Task.isCancelled else { return }
                guard let state, let json = try? Self.json(state) else { continue }
                onEvent(json)
            }
        }
        return PageSubscription { task.cancel() }
    }

    private func profile(_ params: JSONValue) throws -> BrowserSourceProfile {
        let id = try Self.string(params, "id")
        guard let profile = model.importer.profiles.first(where: { $0.id == id }) else { throw PageError.invalidParams("unknown profile") }
        return profile
    }

    private static func string(_ params: JSONValue, _ key: String) throws -> String {
        guard let value = params[key]?.stringValue, !value.isEmpty else { throw PageError.invalidParams("\(key) is required") }
        return value
    }

    nonisolated static func json(_ state: OnboardingPageState) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(state))
    }
}
