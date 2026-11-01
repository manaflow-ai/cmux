public import CmuxNextAgentPane
import CmuxNextDaemon
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

    public init(code: String, machine: String, folder: String? = nil, detail: String? = nil, keyedRestartSafe: Bool? = nil) {
        (self.code, self.machine, self.folder, self.detail, self.keyedRestartSafe) = (code, machine, folder, detail, keyedRestartSafe)
    }

    /// No folder to start in (no seed folder, no folder in the workspace). The App names it
    /// `AgentRemoteStartRefusal.folderNeededCode` (AgentTabs+RemoteStart.swift, where the defaults
    /// guard tracks it); AgentRemoteStartRefusalCodeTests keeps the two equal.
    static let appFolderNeeded = "app.folder_needed"
    /// The tab's host names another machine than the store that lists it (MachineRegistry).
    public static let hostMismatchCode = "app.host_mismatch"

    public static func folderNeeded(machine: String) -> Self { Self(code: appFolderNeeded, machine: machine) }
    /// The refusal of a start on a teammate's machine (the card's New Cloud Machine, startRefusal.ts).
    public static func teamMachine(machine: String) -> Self { Self(code: AgentSessionAttachError.teamMachine, machine: machine) }
    /// An untrusted folder on a machine whose cmux-tui cannot take the person's Trust from here.
    public var withoutTrust: Self { code == "agent_session.untrusted_folder" ? Self(code: "app.trust_update", machine: machine, folder: folder) : self }
    /// The refusals of a start that an older daemon on the machine gives where its current build
    /// would start the chat: a team VM's (`team_vm_blocked`, before cmux#29107) and an owner check
    /// that daemon cannot take (`host_unverified`, a daemon without the caller's `vm_kind` word).
    /// `AgentTabRemoteHost.updateMachine` runs only while the link's owner answer says the machine is the caller's,
    /// so a teammate's machine is never retried (the app refuses that start before it is sent).
    public static let olderDaemonCodes: Set<String> = [AgentSessionAttachError.teamMachine, "agent_session.host_unverified"]
    public static func startUnsupported(machine: String) -> Self { Self(code: AgentSessionAttachClient.startUnsupported, machine: machine) }

    public var userMessage: String { errorDescription ?? code }

    public var machineName: String? { machine.isEmpty ? nil : machine }

    public var errorDescription: String? {
        switch code {
        case "agent_session.untrusted_folder":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.untrustedFolder",
                                  "%1$@ is not a trusted folder on %2$@. Trust it on that machine, then start the chat again.",
                                  folder ?? "~", machine)
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
                                  "The cmux-tui on %@ cannot start agent chats yet. Update cmux-tui on that machine.", machine)
        case "agent_session.acpmux_unavailable":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.agentServiceDown",
                                  "The agent service on %@ did not start.", machine)
        case "agent_session.limit":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.busy",
                                  "%@ is starting other agent chats. Try again in a moment.", machine)
        case "agent_session.timeout":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.timeout",
                                  "%@ did not start the agent in time. Try again.", machine)
        case "agent_session.home_unconfirmed": RefusalStrings.format("handlers.refusal.agentRemoteStart.homeUnconfirmed", "Choose the home folder on %@ with Use Home Folder first.", machine)
        case "agent_session.above_home": RefusalStrings.format("handlers.refusal.agentRemoteStart.aboveHome", "A chat on %@ never runs in a folder above its home folder.", machine)
        case "app.trust_update":
            RefusalStrings.format("handlers.refusal.agentRemoteStart.updateForTrust", "Update cmux on %@ to trust folders from here.", machine)
        case Self.appFolderNeeded:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.folderNeeded",
                                  "%@ has no work folder to start in. Use Choose folder to pick one there.", machine)
        case Self.hostMismatchCode:
            RefusalStrings.text("handlers.refusal.agentRemoteStart.hostMismatch",
                                "This chat belongs to another machine, so it does not run here.")
        default:
            RefusalStrings.format("handlers.refusal.agentRemoteStart.refused",
                                  "%1$@ refused to start the agent chat (%2$@).", machine, code)
        }
    }
}

/// The pane host of an agent tab that cannot show its chat: its handshake says why (no chat on
/// this Mac in its place).
public nonisolated struct AgentTabRefusedHost: AgentPaneHostProviding {
    public let refusal: AgentRemoteStartRefusal

    public init(refusal: AgentRemoteStartRefusal) { self.refusal = refusal }

    public func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw refusal }
}
