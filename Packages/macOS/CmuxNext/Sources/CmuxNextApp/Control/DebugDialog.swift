import CmuxNextCloudUI
import AppKit
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextMobileHost
import CmuxNextOnboarding
import CmuxNextSessionTransfer
import CmuxNextCloud
import CmuxNextSettings

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.dialog`: every open cmux dialog for automation (R96), through the
/// same center path a click takes.
/// - `{}` lists the open dialogs (id, title, lines, origin, scope, visible,
///   buttons, field values, frame in window coordinates).
/// - `{open: "confirm" | "text" | "credentials" | "save" | "choice" | "sessionMove" | "sessionMoveEnd" | "cloudCreateBefore" | "cloudWorkspaceEmpty" | "cloudWorkspaceRepository" | "cloudWorkspaceTeam" | "cloudWorkspaceCompact" | "cloudWorkspaceActions" | "cloudCredentials",
///   scope: "window" | "app", origin?}`
///   shows a fixture (screenshots, latency) and returns its id.
/// - `{id?, set: {field: string | bool}}`, `{id?, key: "return" | "escape" | "tab" | "shift-tab" | "cmd-<c>"}`,
///   `{id?, press: "<button>"}`, `{id?, dismiss: true}` act on dialog `id`
///   (default: the newest visible one).
@MainActor
enum DebugDialog {
    /// Dialogs only the user answers: a clipboard read (CLIPBOARD-READ-BROKER), the Enable
    /// harness sheet (a folder's program would run with the user's rights), the Cloud machine create confirmation (a spend
    /// the person approves, cx-t2rz), a browser pairing (it admits a client to the whole daemon, cx-hnmbt.2), an iPhone pairing,
    /// an ssh:// link from another app (it connects to a host a web page chose), and a cmux://session
    /// link's new tab (any page or app can open the link).
    static let userOnly: Set<String> = [ClipboardReadStrings.identifier, AgentPaneView.harnessEnableIdentifier, CloudPresenter.createConfirmIdentifier, CloudPresenter.environmentConfirmIdentifier, CloudPresenter.credentialRecoveryIdentifier, CloudPresenter.codexDeviceCodeIdentifier,
                                        CloudWorkspaceSetupWizard.credentialDialogIdentifier, DaemonPairingStrings.identifier, IPhoneHostService.pairDialogIdentifier, ExternalLinkGate.sshDialogIdentifier,
                                        SessionLinkGate.dialogIdentifier]

    static func run(_ params: [String: JSONValue], _ services: AppServices) -> JSONValue {
        let center = CmuxDialogCenter.shared
        var result: [String: JSONValue] = [:]
        if let fixture = params["open"]?.stringValue {
            if fixture == "cloudCreateBefore" {
                // Previous default unnamed-machine approval, through the existing presenter.
                // An inert completion means this fixture can never create or approve a VM.
                CloudPresenter.confirm(CloudStrings.createConfirmTitle, CloudStrings.createConfirmApproval,
                                       button: CloudStrings.createConfirmButton,
                                       identifier: CloudPresenter.createConfirmIdentifier,
                                       in: services.windows.active?.window) { _ in }
                if let id = center.records.last(where: \.visible)?.id {
                    result["opened"] = .number(Double(id))
                }
            } else {
                guard let spec = fixtures(origin: params["origin"]?.stringValue)[fixture] else {
                    return .object(["error": .string("unknown fixture \(fixture)")])
                }
                let window = services.windows.active?.window
                let scope: CmuxDialogScope = if params["scope"]?.stringValue != "app", let window { .window(window) } else { .app }
                result["opened"] = .number(Double(center.present(spec, in: scope) { _ in }))
            }
        }
        let target = params["id"]?.intValue ?? center.records.last(where: \.visible)?.id
        // Only the user answers a clipboard read (CLIPBOARD-READ-BROKER);
        // automation may dismiss it, which refuses the read.
        if let target, let identifier = center.record(target)?.spec.identifier, userOnly.contains(identifier),
           params["set"] != nil || params["key"] != nil || params["press"] != nil {
            result["error"] = .string("this dialog answers only to the user")
        } else if let target {
            if case .object(let fields)? = params["set"] {
                for (field, value) in fields {
                    let typed: CmuxDialogValue? = value.boolValue.map(CmuxDialogValue.bool) ?? value.stringValue.map(CmuxDialogValue.text)
                    result["set.\(field)"] = .bool(typed.map { center.setValue($0, for: field, in: target) } ?? false)
                }
            }
            if let name = params["key"]?.stringValue {
                result["key"] = .bool(key(name).map { center.key($0.0, modifiers: $0.1, in: target) } ?? false)
            }
            if let button = params["press"]?.stringValue { result["pressed"] = .bool(center.press(target, button: button)) }
            if params["dismiss"]?.boolValue == true { result["dismissed"] = .bool(center.dismiss(target)) }
        }
        result["dialogs"] = .array(center.records.map { report($0, view: center.view($0.id)) })
        return .object(result)
    }

    private static func key(_ name: String) -> (CmuxDialogKeys.Key, CmuxDialogKeys.Modifiers)? {
        switch name {
        case "return": return (.return, [])
        case "escape": return (.escape, [])
        case "tab": return (.tab, [])
        case "shift-tab": return (.tab, .shift)
        default:
            guard name.hasPrefix("cmd-"), name.count == 5, let character = name.last else { return nil }
            return (.character(character), .command)
        }
    }

    private static func report(_ record: CmuxDialogCenter.Record, view: CmuxDialogView?) -> JSONValue {
        var values: [String: JSONValue] = [:]
        for (field, value) in record.values {
            switch value {
            case .text(let text): values[field] = .string(text)
            case .bool(let on): values[field] = .bool(on)
            }
        }
        var object: [String: JSONValue] = [
            "id": .number(Double(record.id)), "title": .string(record.spec.title),
            "identifier": record.spec.identifier.map { .string($0) } ?? .null,
            "lines": .array(record.spec.lines.map { .string($0) }), "scope": .string(record.scope),
            "visible": .bool(record.visible), "values": .object(values),
            "buttons": .array(record.spec.buttons.map { button in
                .object(["id": .string(button.id), "title": .string(button.title), "role": .string(button.role.rawValue),
                         "key": button.key.map { .string(String($0)) } ?? .null])
            }),
        ]
        if let origin = record.spec.origin { object["origin"] = .string(origin) }
        // Each choice field's options (label and value), so a check can read what a menu offers.
        var options: [String: JSONValue] = [:]
        for case .choice(let id, _, let choices, _) in record.spec.fields {
            options[id] = .array(choices.map { .object(["label": .string($0.label), "value": .string($0.value)]) })
        }
        if !options.isEmpty { object["options"] = .object(options) }
        if let view, view.window != nil {
            let frame = view.convert(view.bounds, to: nil)
            object["frame"] = .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) })
            object["window"] = .number(Double(view.window?.windowNumber ?? 0))
        }
        return .object(object)
    }

    /// Debug-only fixtures (English only: they never ship).
    private static func codexRecoveryFixture(body: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: "Set up Codex on paint?",
            lines: [body, "This replaces Codex's login on this VM and restarts this chat before retrying its failed prompt."],
            buttons: [.cancel("Cancel"), CmuxDialogButton(id: "transfer", title: "Transfer and restart", role: .default)],
            identifier: CloudPresenter.credentialRecoveryIdentifier)
    }

    private static func fixtures(origin: String?) -> [String: CmuxDialogSpec] {
        [
            // Inert native auth fixtures: no account, VM, browser, or credentials are accessed.
            "cloudCodexDevice": CloudPresenter.codexDeviceDialogSpec(code: "DEMO-CODE"),
            "cloudCodexRecovery": codexRecoveryFixture(body: CloudPresenter.codexBrokerDisclosure),
            "cloudCodexRecoveryBefore": codexRecoveryFixture(body: "cmux will start a fresh Codex device login in a visible local terminal for this VM. Codex refresh credentials are never copied between VMs; Codex requires a separate sign-in for each VM."),
            "confirm": CmuxDialogSpec(title: "Close Workspace “api”?", lines: ["vim and npm are still running."],
                                      buttons: [.cancel(), CmuxDialogButton(id: "close", title: "Close", role: .destructive)],
                                      identifier: "cmux.dialog.fixture.confirm"),
            "text": CmuxDialogSpec(title: "Rename Tab", fields: [.text("name", initial: "zsh")],
                                   buttons: [.cancel(), CmuxDialogButton(id: "rename", title: "Rename", role: .default)],
                                   identifier: "cmux.dialog.fixture.text"),
            "credentials": CmuxDialogSpec(
                title: "Sign in to example.com", lines: ["The server asks for a user name and password."],
                origin: origin ?? "https://example.com",
                fields: [.text("user", label: "User Name"),
                         .text(id: "password", label: "Password", initial: "", placeholder: nil, secure: true)],
                buttons: [.cancel(), CmuxDialogButton(id: "sign-in", title: "Sign In", role: .default)],
                identifier: "cmux.dialog.fixture.credentials"),
            "save": CmuxDialogSpec(title: "Save changes to “notes.md”?", lines: ["Your changes are lost if you do not save them."],
                                   buttons: [CmuxDialogButton(id: "dont-save", title: "Don't Save", role: .destructive, key: "d"),
                                             .cancel(), CmuxDialogButton(id: "save", title: "Save", role: .default)],
                                   identifier: "cmux.dialog.fixture.save"),
            "choice": CmuxDialogSpec(title: "Choose a Region", fields: [
                .choice(id: "region", label: nil, options: [CmuxDialogOption(label: "US West", value: "us-west"),
                                                            CmuxDialogOption(label: "EU Central", value: "eu-central")],
                        selected: "us-west"),
                .check(id: "remember", title: "Don't ask again", on: false),
            ], buttons: [.cancel(), CmuxDialogButton(id: "select", title: "Select", role: .default)],
            identifier: "cmux.dialog.fixture.choice"),
            // Gallery variants keep the setup surface reviewable without provisioning a VM.
            "cloudWorkspaceEmpty": CloudWorkspaceSetupWizard.setupDialogSpec(source: .empty),
            "cloudWorkspaceRepository": CloudWorkspaceSetupWizard.setupDialogSpec(source: .repository, repository: "octo/paint"),
            "cloudWorkspaceTeam": CloudWorkspaceSetupWizard.setupDialogSpec(availability: .teamMachine, source: .empty),
            // Gallery-only alternatives: compare the selected labeled form with a compact choice
            // and with explicit source actions. These fixtures never ship or change production flow.
            "cloudWorkspaceCompact": CmuxDialogSpec(
                title: "New Cloud Workspace",
                lines: ["Choose a starting point. A repository is cloned into ~/work on the new VM."],
                fields: [
                    .choice(id: "source", label: nil,
                            options: [CmuxDialogOption(label: "Empty VM — start a new project", value: "empty"),
                                      CmuxDialogOption(label: "From repository", value: "repository")],
                            selected: "empty"),
                    .text("repository", initial: "octo/paint", label: nil,
                          placeholder: "owner/repository or GitHub URL"),
                ],
                buttons: [.cancel(), CmuxDialogButton(id: "create", title: "Create workspace", role: .default)],
                identifier: "cmux.dialog.cloud.workspaceCompact"),
            "cloudWorkspaceActions": CmuxDialogSpec(
                title: "New Cloud Workspace",
                lines: ["Choose a starting point. A repository is cloned into ~/work on the new VM."],
                fields: [.text("repository", initial: "octo/paint", label: "GitHub repository",
                               placeholder: "owner/repository or GitHub URL")],
                buttons: [
                    .cancel(),
                    CmuxDialogButton(id: "empty", title: "Empty VM", role: .normal),
                    CmuxDialogButton(id: "repository", title: "From repository", role: .normal),
                ],
                identifier: "cmux.dialog.cloud.workspaceActions"),
            "cloudCredentials": CloudWorkspaceSetupWizard.credentialDialogSpec(machine: "paint", account: "Personal account"),
            // Move Sessions from Another cmux Build (session.moveFromBuild), with no other build running.
            "sessionMove": SessionMoveSelection(peers: [moveFixturePeer]).dialog,
            "sessionMoveEnd": SessionMoveSelection.endTerminalsDialog(for: ["~/code/app"]),
        ]
    }

    /// A build with a chat, an agent, an idle terminal, a busy one and one that did not say.
    private static var moveFixturePeer: SessionTransferPeer {
        func item(_ id: String, _ kind: SessionTransferItem.Kind, _ title: String,
                  _ activity: SessionTransferItem.Activity = .unknown) -> SessionTransferItem {
            var item = SessionTransferItem(sourceSurface: id, workspace: "w", kind: kind, title: title, cwd: nil, sshTarget: nil,
                                           command: nil, agentHarness: nil, agentSessionID: nil)
            item.activity = activity
            return item
        }
        return SessionTransferPeer(path: "/tmp/cmux-fixture.sock", app: "cmux NIGHTLY", build: "1", tag: nil, pid: 1, items: [
            item("1", .chat, "Fix the login redirect"), item("2", .agent, "Refactor the parser"),
            item("3", .terminal, "~/code/app", .idle), item("4", .terminal, "server", .running("vim")),
            item("5", .terminal, "logs"),
        ])
    }
}
#endif
