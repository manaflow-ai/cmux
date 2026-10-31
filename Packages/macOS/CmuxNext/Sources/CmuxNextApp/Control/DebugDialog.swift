import CmuxNextCloudUI
import AppKit
import CmuxNextAgentPane
import CmuxNextCredentialVault
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
/// - `{open: "confirm" | "text" | "credentials" | "save" | "choice" | "sessionMove" | "sessionMoveEnd" | "cloudCreateBefore" | "cloudWorkspaceEmpty" | "cloudWorkspaceRepository" | "cloudWorkspaceTeam" | "cloudWorkspaceCompact" | "cloudWorkspaceActions" | "cloudCredentials" | "cloudSetupGitHub" (app: ready | not_connected | not_configured | unknown | device),
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
                                        SessionLinkGate.dialogIdentifier, CredentialVault.entrySheetIdentifier,
                                        CredentialVault.approvalSheetIdentifier, CredentialVaultPageRoute.deleteDialogIdentifier]

    /// The refusal every synthetic-input verb (`debug.mouse`, `debug.key`, `debug.view_key`,
    /// `debug.agent_cursor.click_tag`) returns while a dialog only the person answers is open, in
    /// any window: a scripted click or key could press its button or type into its field (a Credential
    /// Vault approval releases a secret). Nil when none is open.
    static var userOnlyInputRefusal: JSONValue? {
        guard CmuxDialogCenter.shared.records.contains(where: { $0.visible && $0.spec.identifier.map(userOnly.contains) == true }) else { return nil }
        return .object(["error": .string("a dialog that answers only to the user is open")])
    }

    static func secureFields(_ spec: CmuxDialogSpec) -> Set<String> { CmuxDialogDebug().secureFields(spec) }

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
            } else if fixture == "cloudSetupGitHub" {
                // Set Up GitHub on This Machine's confirm for a fixture identity, as the App check
                // `app` answered (ready, not_connected, not_configured, unknown); `device` is the
                // confirm before the App was the default. An inert completion: nothing runs.
                let identity = CloudGitHubSetup.GitIdentity(name: "Ann Lee", email: "ann@example.com")
                let app = params["app"]?.stringValue ?? "ready"
                let body = app == "device" ? CloudStrings.gitHubConfirmBody(name: "Ann Lee", email: "ann@example.com")
                    : CloudGitHubHandlers.confirmBody(identity, app: CloudGitHubApp(rawValue: app) ?? .unknown)
                CloudPresenter.confirm(CloudStrings.gitHubConfirmTitle("demo-cloud"), body, button: CloudStrings.gitHubSetUp,
                                       identifier: "cmux.dialog.cloud.setupGitHub", in: services.windows.active?.window) { _ in }
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
                result["key"] = .bool(CmuxDialogDebug().key(name).map { center.key($0.0, modifiers: $0.1, in: target) } ?? false)
            }
            if let button = params["press"]?.stringValue { result["pressed"] = .bool(center.press(target, button: button)) }
            if params["dismiss"]?.boolValue == true { result["dismissed"] = .bool(center.dismiss(target)) }
        }
        result["dialogs"] = .array(center.records.map { JSONValue(foundation: CmuxDialogDebug().report($0, view: center.view($0.id))) ?? .null })
        return .object(result)
    }

    /// `debug.dialog_strip`: fixture `open` (default `confirm`) opening and closing frame by frame
    /// (``CmuxDialogCenter/frameStrip(_:in:close:leadMs:holdMs:tailMs:scale:dir:)``).
    static func strip(_ params: [String: JSONValue], _ services: AppServices?) async -> JSONValue {
        guard let window = services?.windows.active?.window else { return .object(["error": .string("no window")]) }
        let fixture = params["open"]?.stringValue ?? "confirm"
        guard let spec = fixtures(origin: nil)[fixture] else { return .object(["error": .string("unknown fixture \(fixture)")]) }
        let dir = params["dir"]?.stringValue ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("dialog-strip-\(UUID().uuidString)")
        let report = await CmuxDialogCenter.shared.frameStrip(
            spec, in: window, close: params["close"]?.stringValue ?? "escape", leadMs: params["lead_ms"]?.doubleValue ?? 150,
            holdMs: params["hold_ms"]?.doubleValue ?? 700, tailMs: params["tail_ms"]?.doubleValue ?? 600,
            scale: params["scale"]?.doubleValue ?? 0.5, dir: dir)
        return JSONValue(foundation: report) ?? .null
    }

    /// Debug-only fixtures (English only: they never ship).
    private static func codexRecoveryFixture(body: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: "Set up Codex on paint?",
            lines: [body, "This replaces Codex's login on this VM and restarts this chat before retrying its failed prompt."],
            buttons: [.cancel("Cancel"), CmuxDialogButton(id: "transfer", title: "Transfer and restart", role: .default)],
            identifier: CloudPresenter.credentialRecoveryIdentifier)
    }

    private static func fixtures(origin: String?) -> [String: CmuxDialogSpec] {
        CmuxDialogDebug().fixtures(origin: origin).merging([
            // Inert native auth fixtures: no account, VM, browser, or credentials are accessed.
            "cloudCodexDevice": CloudPresenter.codexDeviceDialogSpec(code: "DEMO-CODE"),
            "cloudCodexRecovery": codexRecoveryFixture(body: CloudPresenter.codexBrokerDisclosure),
            "cloudCodexRecoveryBefore": codexRecoveryFixture(body: "cmux will start a fresh Codex device login in a visible local terminal for this VM. Codex refresh credentials are never copied between VMs; Codex requires a separate sign-in for each VM."),
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
        ]) { _, feature in feature }
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
