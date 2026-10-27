public import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWakeups

/// Set Workspace Localhost (cx-d0d.41, plans/cmux-next/remote-localhost.md 9):
/// whose localhost a workspace's browser tabs reach is the person's own
/// choice, a personal row of the home daemon (`personal-remote-localhost-v1`),
/// not cmux.json. A palette, menu or key run is the person's. Any other run
/// (the CLI, a script, a page) applies only after the person approves it on a
/// native sheet, so an agent in a terminal cannot change it. MCP never offers it.
extension ActionRegistry {
    /// Runs `workspace.setRemoteLocalhost`. `workspace` resolves the
    /// invocation's workspace (id and name); `approve` shows the native sheet
    /// for a workspace name and choice title and returns whether the person
    /// confirmed it.
    public func setWorkspaceLocalhost(_ invocation: ActionInvocation, workspace: () throws -> (id: String, name: String),
                                      machines: any RemoteLocalhostMachines,
                                      approve: @escaping @MainActor @Sendable (_ workspace: String, _ choice: String) async -> Bool) throws {
        let raw = invocation["localhost"]?.stringValue ?? ""
        // machine: the workspace's machine; thisMac: this Mac; setting: follow the setting (nil).
        let choices: [String: Bool?] = ["machine": true, "thisMac": false, "setting": nil]
        guard let choice = choices[raw] else { throw ActionFailure.invalidTarget(RefusalStrings.unknownLocalhostChoice(raw)) }
        let model = try workspace()
        guard let address = machines.personalAddress(ofWorkspace: model.id) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        let request = SetPersonalWorkspaceRequest(sessionID: address.session, workspaceKey: WorkspaceKey(rawValue: address.key),
                                                  remoteLocalhost: choice.map { .set($0) } ?? .clear)
        let home = machines.local
        guard invocation.origin != .user else {
            home.send("set-personal-workspace") { try await $0.setPersonalWorkspace(request) }
            return
        }
        let name = Self.quoted(model.name), title = choiceTitle(raw)
        // main-hop-allow: tracked for the capturing caller (the CLI, a script): it awaits the person's main-actor sheet and then the home daemon's write; the router never cancels tracked work
        track(Task {
            // The sheet goes before the caller stops waiting: a change nobody waits for never happens. The limit is a
            // Deadline race (flexible, never sooner); the sheet is cancelled when it wins.
            let approved = await Deadline(ActionDescriptor.resultDeadline - .seconds(5)).value("remote-localhost-approval") {
                await approve(name, title)
            }
            guard approved == true else {
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.localhostChoiceNotApproved)
            }
            return await home.failure("set-personal-workspace") { try await $0.setPersonalWorkspace(request) }
        })
    }

    /// The workspace's name for the sheet: one quoted line, so a name an
    /// agent chose cannot read as part of the question.
    private static func quoted(_ name: String) -> String {
        let line = name.split(whereSeparator: \.isNewline).joined(separator: " ")
        let shown = line.count > 60 ? String(line.prefix(59)) + "\u{2026}" : line
        return "\u{201C}\(shown)\u{201D}"
    }

    /// The menu title of a choice, for the sheet.
    private func choiceTitle(_ value: String) -> String {
        let argument = descriptor(for: "workspace.setRemoteLocalhost")?.arguments.first { $0.name == "localhost" }
        guard case .enumeration(let cases)? = argument?.kind else { return value }
        return cases.first { $0.value == value }?.title ?? value
    }
}

extension RefusalStrings {
    static func unknownLocalhostChoice(_ value: String) -> String {
        format("handlers.refusal.unknownLocalhostChoice", "Unknown localhost '%@' (use machine, thisMac or setting)", value)
    }

    static var localhostChoiceNotApproved: String {
        text("handlers.refusal.localhostChoiceNotApproved", "Not changed: the change was not approved in cmux.")
    }
}
