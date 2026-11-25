import CmuxNextBrowserImport
import CmuxNextCompat
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Serves the onboarding page from the window's ``OnboardingModel``: `cmux.onboarding.state`, the
/// `cmux.onboarding.changed` stream (the whole state after each model or icon change, coalesced,
/// only when it differs), and the gestures, each a model call. A gesture runs only on a real
/// click or key in the page (`PageCallContext.userGesture`, the host's record), and each click or
/// key runs one gesture (its `gestureEvent` is spent): nothing a page sends on its own can install
/// an agent, start an import, a sign-in or a System Settings grant, or run a second one off the
/// same click. This is the rule of the app's other pages with person-only ops (Settings' agents,
/// the agent pane). A VoiceOver press carries no key or mouse event; in Chromium it counts as the
/// gesture all the same (`ChromiumAccessibilityPress`: only an assistive app reaches it). In WebKit,
/// where VoiceOver talks to the web process directly, its trusted click counts while VoiceOver runs
/// (`PageAccessibilityPress`, manaflow-ai/cmux#37809).
/// Full Keyboard Access (Tab, then Space or Return) sends real key events and works in both.
@MainActor
final class OnboardingPageProvider: PageProvider {
    private let model: OnboardingModel
    private let images = OnboardingPageImages()
    /// The click or key the last gesture ran on (`PageCallContext.gestureEvent`).
    private var spentGesture: TimeInterval?
    /// The Agents step's in-place sign-in (``OnboardingSignIn``); nil keeps the step as before.
    private let signIn: OnboardingSignIn?

    init(model: OnboardingModel, signIn: OnboardingSignIn? = nil) {
        self.model = model
        self.signIn = signIn
        guard let signIn, model.step == .agents else { return }
        // task-owner: one read when the window opens; it ends with the read.
        Task { await signIn.refresh() }
    }

    var state: OnboardingPageState {
        OnboardingPageState(model: model, images: images, signIn: model.step == .agents ? signIn?.state() : nil)
    }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        if op == "cmux.onboarding.state" { return try Self.json(state) }
        // The page gained focus. Only a read (after a Sign In, the sign-ins are checked again), so it
        // needs no click or key; a click into the page keys the page engine's child window, which
        // the window's own didBecomeKey does not see.
        if op == "cmux.onboarding.focused" {
            model.windowBecameKey()
            if let signIn, model.step == .agents { await signIn.refresh() }
            return [:]
        }
        if op == OnboardingSignIn.op { return try await runSignIn(params, context: context) }
        guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
            throw PageError(code: PageNativeOp.userOnlyCode, message: "\(op) runs only on its own click or key in the window")
        }
        spentGesture = event
        try perform(op, params)
        return [:]
    }

    /// `cmux.onboarding.accounts.run {action, ...}`: Settings > Accounts' forwarder's answer, unchanged.
    /// A start, switch, sign-out or remove runs only on its own click or key, as every other gesture.
    private func runSignIn(_ params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let signIn, model.step == .agents else { throw PageError.unknownOp(OnboardingSignIn.op) }
        let action = try Self.string(params, "action")
        if !OnboardingSignIn.followUps.contains(action) {
            guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "\(action) runs only on its own click or key in the window")
            }
            spentGesture = event
        }
        guard let reply = try await signIn.run(action, params) else { throw PageError.invalidParams("unknown action") }
        return reply
    }

    /// One gesture on the model. A step's own op runs only while the window shows that step (an
    /// import op on the Agents step is refused), unknown ids and kinds are refused, and a gesture
    /// the model does not take now (a toggle during an import) is the model's no-op.
    func perform(_ op: String, _ params: JSONValue) throws {
        if let step = Self.step(of: op), step != model.step {
            throw PageError.invalidParams("\(op) is the \(step) step's, and the window shows \(model.step)")
        }
        let importer = model.importer
        switch op {
        case "cmux.onboarding.next": model.next()
        case "cmux.onboarding.skip": model.skipStep()
        case "cmux.onboarding.back": model.goBack()
        case "cmux.onboarding.agents.signIn": model.agents.signIn(try Self.string(params, "id"))
        case "cmux.onboarding.agents.install": model.agents.install(try Self.string(params, "id"))
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
        case "cmux.onboarding.makeItYours.workStyle":
            guard let value = WorkStyle(rawValue: try Self.string(params, "value")) else { throw PageError.invalidParams("unknown work style") }
            model.makeItYours.setWorkStyle(value)
        case "cmux.onboarding.makeItYours.density":
            guard model.makeItYours.setDensity(try Self.string(params, "value")) else { throw PageError.invalidParams("unknown density") }
        case "cmux.onboarding.makeItYours.background":
            // null: no background.
            guard model.makeItYours.setBackground(params["id"]?.stringValue) else { throw PageError.invalidParams("unknown background") }
        case "cmux.onboarding.makeItYours.opacity":
            guard let value = params["value"]?.doubleValue, model.makeItYours.setOpacity(value) else { throw PageError.invalidParams("opacity is 0 to 1") }
        case "cmux.onboarding.makeItYours.material":
            guard let value = FirstRunMaterial(rawValue: try Self.string(params, "value")) else { throw PageError.invalidParams("unknown material") }
            model.makeItYours.setMaterial(value)
        case "cmux.onboarding.makeItYours.walk":
            // {writes: [{path: "a.b", value}]}: a missing or null value removes the setting.
            guard let rows = params["writes"]?.arrayValue, !rows.isEmpty else { throw PageError.invalidParams("writes is required") }
            let writes = try rows.map { row in
                guard let path = row["path"]?.stringValue, !path.isEmpty else { throw PageError.invalidParams("path is required") }
                let value = row["value"].flatMap { $0 == .null ? nil : $0 }
                return FirstRunWalkWrite(path: path.split(separator: ".").map(String.init), value: value)
            }
            guard model.makeItYours.setWalk(writes) else { throw PageError.invalidParams("not a setting the intro writes") }
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

    /// The step whose controls send `op`: nil for the footer's Next, Skip and Back, which every step has.
    nonisolated static func step(of op: String) -> OnboardingModel.Step? {
        if op.hasPrefix("cmux.onboarding.agents.") { return .agents }
        if op.hasPrefix("cmux.onboarding.import.") { return .importData }
        if op.hasPrefix("cmux.onboarding.computerUse.") { return .computerUse }
        if op.hasPrefix("cmux.onboarding.makeItYours.") { return .makeItYours }
        return nil
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
