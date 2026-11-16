public import CmuxNextAgentPane
public import CmuxNextDaemon
public import Foundation

/// Why a chat could not start on another machine, in the user's language. ONE table maps every
/// typed refusal of `agent-session-start` (cmux-tui/spec/commands.md) and the app's own checks.
public nonisolated struct AgentRemoteStartRefusal: LocalizedError, AgentPaneHostRefusal, Equatable {
    public let code: String
    public let machine: String
    public var folder: String?
    public var detail: String?
    /// `agent_session.needs_keyed_start`: the machine's daemon says a keyed restart of its acpmux
    /// loses nothing (cx-0w0jj); nil for any other refusal.
    public var keyedRestartSafe: Bool?
    /// `agent_session.sign_in_required`: the agent's name as a person reads it (Cursor), when the
    /// refusal named its harness, and whether its sign-in expired rather than was never made (hq#11225).
    /// `agent_session.harness_missing` and `agent_session.route_unavailable` name their agent the same way, from
    /// the refusal's `data.harness` only.
    public var agentName: String?
    public var signInExpired = false
    /// The refused harness id from the refusal's `data` (`cmux`, the cmux router), for a refusal that names one.
    public var harness: String?
    /// The machine's acpmux reason code (`data.reason`, such as `permission.denied`) of a refusal this table has no
    /// words for: the message names it beside the code, so a bare `agent_session.refused` never hides the cause
    /// (the Cloud carrier drill, cmuxterm-hq run 43973035740). Nil when the refusal gave none.
    public var reason: String?

    public init(code: String, machine: String, folder: String? = nil, detail: String? = nil, keyedRestartSafe: Bool? = nil,
                agentName: String? = nil, signInExpired: Bool = false, harness: String? = nil, reason: String? = nil) {
        (self.code, self.machine, self.folder, self.detail, self.keyedRestartSafe) = (code, machine, folder, detail, keyedRestartSafe)
        (self.agentName, self.signInExpired, self.harness, self.reason) = (agentName, signInExpired, harness, reason)
    }

    /// A start refused because its agent is not signed in on the machine (cmux-tui
    /// `StartRefused::of_session_new`, hq#11225): its `data` names the harness and `errorKind`.
    public static let signInRequiredCode = "agent_session.sign_in_required"
    /// A start of an agent the machine's acpmux does not have (cmux-tui `start_family`, hq#11225): its `data`
    /// is `{reason: "agent.not_installed", harness}`, `harness` only when it is a valid harness id.
    public static let harnessMissingCode = "agent_session.harness_missing"
    /// A start whose agent's model route cannot serve it on the machine (cmux-tui `StartRefused::naming`: the
    /// cmux router on a Cloud machine with no signed-in local router), `data {reason, harness}` (hq#11225).
    public static let routeUnavailableCode = "agent_session.route_unavailable"
    /// The cmux router's harness id: its route refusal names the router.
    public static let cmuxRouterHarness = "cmux"

    /// `agent-session-start`'s refusal `error` on `machine`, coded `code` (the card's code, AgentSessionAttachError.classified):
    /// its folder, words and keyed-restart answer, and for an agent not signed in its name (`name` of the refusal's
    /// harness, else `harness`, the one asked for) and whether its sign-in expired (hq#11225).
    public static func refused(_ error: AgentSessionAttachError, code: String, machine: String, folder: String?, harness: String?,
                               name: (String) -> String) -> Self {
        let signIn = code == signInRequiredCode
        let dataHarness = error.details?["harness"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // A missing agent or an unserved route names the harness its `data` names, never a guess (hq#11225).
        let named = code == harnessMissingCode || code == routeUnavailableCode
        let refusedHarness = signIn ? dataHarness ?? harness : named ? dataHarness : nil
        return Self(code: code, machine: machine, folder: folder, detail: error.message, keyedRestartSafe: error.keyedRestartSafe,
                    agentName: refusedHarness.flatMap { $0.isEmpty ? nil : name($0) },
                    signInExpired: signIn && error.details?["errorKind"]?.stringValue == "auth.expired",
                    harness: named ? dataHarness : nil, reason: reasonCode(error.details?["reason"]?.stringValue))
    }

    /// `text` when it is a short reason code (letters, digits, `._-`, at most 64), as the machine sends one; never prose.
    static func reasonCode(_ text: String?) -> String? {
        guard let text, (1...64).contains(text.count) else { return nil }
        let code = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return text.unicodeScalars.allSatisfy(code.contains) ? text : nil
    }

    /// The refusal's typed facts for the page (`data` of its JSON-RPC error): an agent not signed in
    /// says so in acpmux's own words (`reason` `agent.sign_in_required`, `errorKind`), so the page
    /// names the cause and offers the agent's sign-in. Never the refusal's text.
    public var pageFacts: [String: String] {
        guard code == Self.signInRequiredCode else { return [:] }
        return ["reason": "agent.sign_in_required", "errorKind": signInExpired ? "auth.expired" : "auth.signed_out"]
    }

    /// No folder to start in (no seed folder, no folder in the workspace). The App names it
    /// `AgentRemoteStartRefusal.folderNeededCode` (AgentTabs+RemoteStart.swift, where the defaults
    /// guard tracks it); AgentRemoteStartRefusalCodeTests keeps the two equal.
    static let appFolderNeeded = "app.folder_needed"
    /// The tab's host names another machine than the store that lists it (MachineRegistry); `machine`
    /// is the machine the chat belongs to.
    public static let hostMismatchCode = "app.host_mismatch"
    /// A tab of this Mac's chat that another machine's store lists; `machine` is that machine.
    public static let listedElsewhereCode = "app.listed_elsewhere"

    public static func folderNeeded(machine: String) -> Self { Self(code: appFolderNeeded, machine: machine) }
    /// A Cloud start from a folder this Mac does not trust: its copy on the machine is trusted only when this Mac
    /// trusts the folder (cmux-tui `link start-chat copy`'s `source_trusted`), so the machine's agent refuses the copy.
    /// The cause and the fix are on this Mac, never "on that machine". `folder` is the folder on this Mac.
    public static let untrustedSourceCode = "app.untrusted_source"
    public static func untrustedSource(folder: String, machine: String = "") -> Self { Self(code: untrustedSourceCode, machine: machine, folder: folder) }
    /// The refusal of a start on a teammate's machine (the card's New Cloud Machine, startRefusal.ts).
    public static func teamMachine(machine: String) -> Self { Self(code: AgentSessionAttachError.teamMachine, machine: machine) }
    /// An untrusted folder on a machine whose cmux-tui cannot take the person's Trust from here.
    public var withoutTrust: Self { code == "agent_session.untrusted_folder" ? Self(code: "app.trust_update", machine: machine, folder: folder) : self }
    /// The refusals of a start that an older daemon on the machine gives where its current build
    /// would start the chat: a team VM's (`team_vm_blocked`, before cmux#29107) and an owner check
    /// that daemon cannot take (`host_unverified`, a daemon without the caller's `vm_kind` word), and
    /// the app's own `folder_needed` for a chat with no folder on a machine whose cmux-tui predates
    /// no-folder starts (`agent-session-start-no-cwd-v1`; a current one starts it in `~/chats/<id>`).
    /// `AgentTabRemoteHost.updateMachine` runs only while the link's owner answer says the machine is the caller's,
    /// so a teammate's machine is never retried (the app refuses that start before it is sent), and an
    /// SSH host, which has no update, keeps the folder refusal.
    public static let olderDaemonCodes: Set<String> = [AgentSessionAttachError.teamMachine, "agent_session.host_unverified", appFolderNeeded]
    public static func startUnsupported(machine: String) -> Self { Self(code: AgentSessionAttachClient.startUnsupported, machine: machine) }

    public var userMessage: String { errorDescription ?? code }

    public var machineName: String? { machine.isEmpty ? nil : machine }

    public var errorDescription: String? {
        switch code {
        case "agent_session.untrusted_folder":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.untrustedFolder",
                                  "%1$@ is not a trusted folder on %2$@. Trust it on that machine, then start the chat again.",
                                  folder ?? "~", machine)
        case Self.untrustedSourceCode:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.untrustedSource",
                                  "This Mac doesn't trust %1$@, so its copy on a Cloud machine isn't trusted either. Trust it on this Mac (Trust Folder in a chat in that folder, or `cmux setup trust %2$@`), then start the chat again.",
                                  folder ?? "~", Self.shellWord(folder ?? "~"))
        case "agent_session.not_asking":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.harnessRefused",
                                  "This agent cannot ask before it acts on %@, so it cannot run there from this Mac. Pick another agent.", machine)
        case AgentSessionAttachError.teamMachine:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.teamVM",
                                  "%@ is a teammate's machine, so its owner starts chats there. Pick your own machine, or create one with New Cloud Machine.", machine)
        case "agent_session.host_unverified":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.hostUnverified",
                                  "%@ could not confirm what kind of Cloud machine it is, so no agent chat starts there.", machine)
        case AgentSessionAttachClient.startUnsupported, "agent_session.unsupported":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.updateRemote",
                                  "cmux on %@ can't start agent chats yet. Update cmux on that machine.", machine)
        case "agent_session.acpmux_unavailable":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.agentServiceDown",
                                  "The agent service on %@ did not start.", machine)
        case "agent_session.limit":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.busy",
                                  "%@ is starting other agent chats. Try again in a moment.", machine)
        case "agent_session.timeout":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.timeout",
                                  "%@ did not start the agent in time. Try again.", machine)
        case Self.signInRequiredCode where signInExpired:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.signInExpired",
                                  "%1$@'s sign-in expired on %2$@. Sign it in again there, then start the chat again.",
                                  agentName ?? RefusalStrings.text("handlers.refusal.agentRemoteStart.thisAgent", "This agent"), machine)
        case Self.signInRequiredCode:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.signInRequired",
                                  "%1$@ isn't signed in on %2$@. Sign it in there, then start the chat again.",
                                  agentName ?? RefusalStrings.text("handlers.refusal.agentRemoteStart.thisAgent", "This agent"), machine)
        case Self.harnessMissingCode:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.harnessMissing",
                                  "%1$@ isn't installed on %2$@. Install it there or pick another agent, then start the chat again.",
                                  agentName ?? RefusalStrings.text("handlers.refusal.agentRemoteStart.thisAgent", "This agent"), machine)
        case Self.routeUnavailableCode where harness == Self.cmuxRouterHarness:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.routerUnavailable",
                                  "The cmux router isn't available on %@. Pick another agent, or start the chat again later.", machine)
        case Self.routeUnavailableCode:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.routeUnavailable",
                                  "%1$@'s model route isn't available on %2$@. Pick another agent, or start the chat again later.",
                                  agentName ?? RefusalStrings.text("handlers.refusal.agentRemoteStart.thisAgent", "This agent"), machine)
        case "agent_session.home_unconfirmed": RefusalStrings.format("handlers.refusal.agentRemoteStart.homeUnconfirmed", "Choose the home folder on %@ with Use Home Folder first.", machine)
        case "agent_session.above_home": RefusalStrings.format("handlers.refusal.agentRemoteStart.aboveHome", "A chat on %@ never runs in a folder above its home folder.", machine)
        case "app.trust_update":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.updateForTrust", "Update cmux on %@ to trust folders from here.", machine)
        case Self.appFolderNeeded:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.folderNeeded",
                                  "%@ has no work folder to start in. Use Choose folder to pick one there.", machine)
        case Self.hostMismatchCode:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.belongsTo",
                                  "This chat belongs to %@, so it does not run on this Mac.", machine)
        case Self.listedElsewhereCode:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.listedElsewhere",
                                  "This chat belongs to this Mac, so it does not run on %@.", machine)
        default:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.refused",
                                  "%1$@ refused to start the agent chat (%2$@).", machine, reason.map { "\(code): \($0)" } ?? code)
        }
    }
}

nonisolated extension AgentRemoteStartRefusal {
    /// `text` as one shell word: as it is when it needs no quoting, else in single quotes.
    static func shellWord(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%")
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) else {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return text
    }
}

/// The pane host of an agent tab that cannot show its chat: its handshake says why (no chat on
/// this Mac in its place).
public nonisolated struct AgentTabRefusedHost: AgentPaneHostProviding {
    public let refusal: AgentRemoteStartRefusal

    public init(refusal: AgentRemoteStartRefusal) { self.refusal = refusal }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw refusal }
}
