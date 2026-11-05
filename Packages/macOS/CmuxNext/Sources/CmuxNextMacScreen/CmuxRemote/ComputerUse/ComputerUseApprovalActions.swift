public import AppKit
public import CmuxNextActions
public import CmuxNextComputerUse
public import CmuxNextControl
import CmuxNextDesign
public import CmuxNextSettings

/// Computer Use approvals' palette actions and app socket methods
/// (docs/computer-use-approvals.md, "Controls" and "Mac app wire"). Nothing here decides a
/// question: `prompt` only shows its card again. Revoking and a lower mode apply at once;
/// a higher mode asked from the socket waits for the person's confirmation on a cmux dialog.
extension ComputerUseApprovalService {
    /// The App's one `computer_use.status`: Computer Use Setup's phase and grants (`setup`: the agent
    /// setup check, `cmux agents doctor`, `cmux setup computer-use`) with the approvals' mode, worker
    /// and lists (`cmux computer-use status`; docs/computer-use-approvals.md, "Mac app wire"). Two
    /// methods of that name replaced each other, so the setup fields were lost and the agent check let
    /// every call through. The setup's fields win a shared key.
    public func status(setup: JSONValue) -> JSONValue {
        guard case .object(var fields) = setup else { return .object(ComputerUseApprovalActions.statusFields(self)) }
        for (key, value) in ComputerUseApprovalActions.statusFields(self) where fields[key] == nil { fields[key] = value }
        return .object(fields)
    }

    /// Binds the palette actions (`computerUse.showStatus`, `computerUse.revokeSavedApprovals`).
    public func bindActions(into registry: ActionRegistry, window: @escaping @MainActor () -> NSWindow?) {
        ComputerUseApprovalActions.bind(into: registry, service: self, window: window)
    }

    /// The app socket methods (docs/computer-use-approvals.md, "Mac app wire").
    public func controlMethods(window: @escaping @MainActor () -> NSWindow?) -> [ControlMethod] {
        var methods = ComputerUseApprovalActions.methods(service: self, window: window)
        #if DEBUG
        // DEBUG only (a release build has no such method): the real card with a fixture question.
        methods.append(.mainActor("debug.computer_use_card") { [cards] call in .value(cards.debugFixture(call.params)) })
        #endif
        return methods
    }
}

#if DEBUG
extension ComputerUseApprovalCards {
    /// `debug.computer_use_card`: the real approval card with a fixture question (Claude in
    /// workspace "api-server" wants to use Safari, from this app's bundle id), for captures. The
    /// card is on no broker and no worker link: any press only closes it and decides nothing
    /// (ComputerUseApprovalCardFixtureTests).
    /// - `{}` shows it and returns its card id.
    /// - `{"action": "dismiss"}` closes every fixture card.
    func debugFixture(_ params: [String: JSONValue]) -> JSONValue {
        if params["action"]?.stringValue == "dismiss" { return .object(["dismissed": JSONValue(dismissFixtures())]) }
        let client = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next"
        guard let request = Self.fixtureRequest(client: client, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) else {
            return .object(["error": .string("the fixture request did not build for client \(client)")])
        }
        return .object(["shown": .string(showFixture(request)), "agent": .string(request.agent), "workspace": .string(request.workspace),
                        "target": .string(request.target.bundleID ?? "")])
    }
}
#endif

@MainActor
enum ComputerUseApprovalActions {
    static func bind(into registry: ActionRegistry, service: ComputerUseApprovalService,
                     window: @escaping @MainActor () -> NSWindow?) {
        registry.bindEffect("computerUse.showStatus", effect: { _ in
            let spec = CmuxDialogSpec(title: ComputerUseApprovalStrings.statusTitle,
                                      lines: ComputerUseApprovalStrings.statusLines(mode: service.mode, phoneAlwaysAllow: service.phoneAlwaysAllow,
                                                                                     saved: service.store.apps.map(\.app.name),
                                                                                     pending: service.broker.pending.count),
                                      buttons: [.ok()], identifier: "cmux.dialog.computerUse.status")
            CmuxDialogCenter.shared.present(spec, in: scope(window())) { _ in }
            return .done
        })
        registry.bindEffect("computerUse.revokeSavedApprovals", effect: { _ in
            let apps = service.store.apps.map(\.app)
            let spec = revokeSpec(apps)
            CmuxDialogCenter.shared.present(spec, in: scope(window())) { answer in
                switch answer.button {
                case "all": service.broker.revoke(nil)
                case "chosen":
                    for (index, app) in apps.enumerated() where answer.isOn("app.\(index)") { service.broker.revoke(app) }
                default: break
                }
            }
            return .done
        })
    }

    private static func scope(_ window: NSWindow?) -> CmuxDialogScope { window.map(CmuxDialogScope.window) ?? .app }

    /// The revoke dialog: one check box per saved app, Revoke (the checked ones), Revoke All.
    static func revokeSpec(_ apps: [ComputerUseApprovalApp]) -> CmuxDialogSpec {
        guard !apps.isEmpty else {
            return CmuxDialogSpec(title: ComputerUseApprovalStrings.revokeTitle, lines: [ComputerUseApprovalStrings.revokeNone],
                                  buttons: [.ok()], identifier: "cmux.dialog.computerUse.revoke")
        }
        return CmuxDialogSpec(
            title: ComputerUseApprovalStrings.revokeTitle, lines: [ComputerUseApprovalStrings.revokeBody],
            fields: apps.enumerated().map { index, app in .check(id: "app.\(index)", title: app.name.isEmpty ? (app.identity ?? "") : app.name, on: false) },
            buttons: [.cancel(), CmuxDialogButton(id: "all", title: ComputerUseApprovalStrings.revokeAll, role: .destructive),
                      CmuxDialogButton(id: "chosen", title: ComputerUseApprovalStrings.revokeChosen, role: .default)],
            identifier: "cmux.dialog.computerUse.revoke")
    }

    // MARK: Socket

    /// The approvals' part of `computer_use.status`: mode, phone, worker, saved apps, waiting questions.
    static func statusFields(_ service: ComputerUseApprovalService) -> [String: JSONValue] {
        ["mode": .string(service.mode.rawValue), "phone_always_allow": .bool(service.phoneAlwaysAllow),
         "worker": .string(service.workerState),
         "saved": .array(service.store.apps.map(savedValue)), "pending": .array(service.broker.pending.map(pendingValue))]
    }

    /// `computer_use.approvals.list|revoke|pending|deny|prompt`, `computer_use.mode.set`. `computer_use.status` is the
    /// App's (SettingsControl): Computer Use Setup's fields with ``ComputerUseApprovalService/statusFields``.
    static func methods(service: ComputerUseApprovalService, window: @escaping @MainActor () -> NSWindow?) -> [ControlMethod] {
        [
            .mainActor("computer_use.approvals.list") { _ in .value(list(service)) },
            .mainActor("computer_use.approvals.pending") { _ in .value(["pending": .array(service.broker.pending.map(pendingValue))]) },
            .mainActor("computer_use.approvals.revoke") { call in
                if call.params["all"]?.boolValue == true { return .value(["revoked": JSONValue(service.broker.revoke(nil))]) }
                guard let app = call.params["app"].flatMap(Self.app) else {
                    throw ControlError.invalidParams("pass app {bundle_id|executable} or all: true")
                }
                return .value(["revoked": JSONValue(service.broker.revoke(app))])
            },
            .mainActor("computer_use.approvals.deny") { call in
                guard let id = call.params["id"]?.stringValue, !id.isEmpty else { throw ControlError.invalidParams("pass id") }
                guard service.broker.deny(id) else {
                    throw ControlError(code: "not_found", message: "no waiting Computer Use question \(id)")
                }
                return .value(["ok": true])
            },
            .mainActor("computer_use.approvals.prompt") { call in
                guard let id = call.params["id"]?.stringValue, !id.isEmpty else { throw ControlError.invalidParams("pass id") }
                guard service.broker.prompt(id) else {
                    throw ControlError(code: "not_found", message: "no waiting Computer Use question \(id)")
                }
                return .value(["ok": true])
            },
            .mainActor("computer_use.mode.set") { call in
                guard let mode = call.params["mode"]?.stringValue.flatMap(ComputerUseMode.init(rawValue:)) else {
                    throw ControlError.invalidParams("mode must be ask, bounded, standard or unrestricted")
                }
                guard let settings = service.settingsController else { throw ControlError.invalidParams("settings are not loaded yet") }
                let raise = mode.raises(over: service.mode)
                let (title, body) = ComputerUseApprovalStrings.confirmMode(mode)
                let shown = window()
                return .followUp {
                    if raise {
                        guard await confirmRaise(title: title, body: body, in: shown) else { return ["ok": false, "declined": true] }
                    }
                    // A lower mode narrows what agents may do and needs no one's confirmation; a
                    // higher one counts only after the person confirmed it just now.
                    try await settings.setSetting(at: ComputerUseSettings.modePath, to: .string(mode.rawValue), by: .user)
                    return ["ok": true, "mode": .string(mode.rawValue)]
                }
            }.withDeadline(.fixed(.seconds(130))),
        ]
    }

    /// The person's answer to raising the mode. No button is Return's default: a raise an agent
    /// asked for counts only after a click on Change, never after a key typed for something else.
    static func confirmRaise(title: String, body: String, in window: NSWindow?) async -> Bool {
        let spec = CmuxDialogSpec(title: title, lines: [body],
                                  buttons: [.cancel(), CmuxDialogButton(id: "change", title: ComputerUseApprovalStrings.change, role: .normal)],
                                  identifier: ComputerUseApprovalService.confirmModeDialogIdentifier)
        return await CmuxDialogCenter.shared.present(spec, in: scope(window)).button == "change"
    }

    static func list(_ service: ComputerUseApprovalService) -> JSONValue {
        ["client": .string(service.store.client), "apps": .array(service.store.apps.map(savedValue))]
    }

    static func appValue(_ app: ComputerUseApprovalApp) -> JSONValue {
        var fields: [String: JSONValue] = ["name": .string(app.name)]
        if let bundleID = app.bundleID { fields["bundle_id"] = .string(bundleID) } else if let executable = app.executable { fields["executable"] = .string(executable) }
        return .object(fields)
    }

    static func savedValue(_ saved: ComputerUseSavedApproval) -> JSONValue {
        guard case .object(var fields) = appValue(saved.app) else { return .null }
        fields["added_ms"] = .number(Double(saved.addedMs))
        fields["via"] = .string(saved.via.rawValue)
        return .object(fields)
    }

    static func pendingValue(_ entry: ComputerUseApprovalPending) -> JSONValue {
        let request = entry.request
        return ["id": .string(entry.id), "digest": .string(request.digest), "agent": .string(request.agent),
                "workspace": .string(request.workspace), "client": .string(request.client), "target": appValue(request.target),
                "tool": .string(request.tool), "risk": .string(request.risk),
                "wait_until_ms": .number(Double(request.waitUntilMs)), "answerable_until_ms": .number(Double(request.answerableUntilMs))]
    }

    static func app(_ value: JSONValue) -> ComputerUseApprovalApp? {
        guard case .object(let fields) = value else { return nil }
        return ComputerUseApprovalApp(wire: fields.compactMapValues(\.stringValue))
    }
}
