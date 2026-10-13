import CmuxNextActions
import CmuxNextDaemon

/// Set Workspace Localhost (cx-d0d.41, plans/cmux-next/remote-localhost.md 9):
/// whose localhost a workspace's browser tabs reach is the person's own
/// choice, a personal row of the home daemon (`personal-remote-localhost-v1`),
/// not cmux.json. A palette, menu or key run is the person's. Any other run
/// (the CLI, a script, a page) applies only after the person approves it on a
/// native sheet, so an agent in a terminal cannot change it. MCP never offers it.
enum RemoteLocalhostHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("workspace.setRemoteLocalhost", requires: DaemonCapabilities.shared.personalRemoteLocalhost,
                      daemon: context.services.machines.local, run: { invocation in
            try set(invocation, context)
        })
    }

    private static func set(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let raw = invocation["localhost"]?.stringValue ?? ""
        let choice: Bool?
        switch raw {
        case "machine": choice = true
        case "thisMac": choice = false
        case "setting": choice = nil
        default: throw ActionFailure.invalidTarget(RefusalStrings.unknownLocalhostChoice(raw))
        }
        let (model, _) = try context.workspace(invocation)
        guard let qualified = WindowProfiles.qualified(model.id, machines: context.services.machines) else {
            throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
        }
        let request = SetPersonalWorkspaceRequest(sessionID: qualified.session, workspaceKey: WorkspaceKey(rawValue: qualified.key),
                                                  remoteLocalhost: choice.map { .set($0) } ?? .clear)
        let services = context.services
        guard invocation.origin != .user else {
            services.machines.local.send("set-personal-workspace") { try await $0.setPersonalWorkspace(request) }
            return
        }
        let prompt = DestructiveConfirmation.Prompt(
            title: ConfirmationStrings.remoteLocalhostTitle,
            body: ConfirmationStrings.remoteLocalhostBody(quoted(model.displayName), choiceTitle(raw, services.registry)),
            button: ConfirmationStrings.userOnlySettingButton)
        services.registry.track(Task {
            // The sheet goes before the caller stops waiting (the router never
            // cancels tracked work): a change nobody waits for never happens.
            let sheet = Task { await UserOnlySettingConfirmation.ask(prompt, services: services) }
            let deadline = Task {
                try? await Task.sleep(for: ActionDescriptor.resultDeadline - .seconds(5))
                sheet.cancel()
            }
            defer { deadline.cancel() }
            guard await sheet.value, !sheet.isCancelled else {
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.localhostChoiceNotApproved)
            }
            return await services.machines.local.failure("set-personal-workspace") { try await $0.setPersonalWorkspace(request) }
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
    private static func choiceTitle(_ value: String, _ registry: ActionRegistry) -> String {
        let argument = registry.descriptor(for: "workspace.setRemoteLocalhost")?.arguments.first { $0.name == "localhost" }
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
