public import CmuxNextCloud
import Foundation

/// What `cmux cloud start-session` says (``CloudStartSession``, ``CloudStartSessionAsks``): the
/// start, an agent's ask in its chat, and why either stopped. Each refusal names the machine and the agent and gives the command to run
/// again. Keys live in Resources/CloudSessions.xcstrings with every app locale.
public struct CloudStartSessionStrings {
    public init() {}

    /// What a refusal of an agent's ask names: the machine, the agent and the command to run again.
    public struct Asked: Equatable {
        public var machine: String
        public var agent: String
        public var command: String

        public init(machine: String, agent: String, command: String) {
            (self.machine, self.agent, self.command) = (machine, agent, command)
        }
    }

    public static var start: String { String(localized: "cloud.startSession.start", defaultValue: "Start", table: "CloudSessions", bundle: .localizedModule) }
    public static var openChat: String { String(localized: "cloud.startSession.openChat", defaultValue: "Open Chat", table: "CloudSessions", bundle: .localizedModule) }

    public static func noPage(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.noPage", defaultValue: "Couldn't show the question in the chat, so %2$@ didn't start on %1$@. Run `%3$@` again once the chat is open.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    public static func askOpen(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.askOpen", defaultValue: "This chat already asks the person to start a Cloud session. Wait for their answer, then run `%3$@` again if %2$@ still isn't running on %1$@.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    public static func declined(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.declined", defaultValue: "The person chose Not now, so %2$@ didn't start on %1$@. Ask them in the chat before you run `%3$@` again.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    public static func expired(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.expired", defaultValue: "Nobody answered the question in the chat within 2 minutes, so %2$@ didn't start on %1$@. Run `%3$@` again when the person is there.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    /// The signed-in account or team changed while the ask or its run waited.
    public static func accountChanged(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.accountChanged", defaultValue: "Your Cloud account or team changed after this was asked, so %2$@ didn't start on %1$@. Run `%3$@` again in the account you want it in.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    /// The signed-in account or team changed after Start, while the run went on: it stopped.
    public static func accountChangedWhileStarting(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.accountChangedWhileStarting", defaultValue: "Your Cloud account or team changed while %2$@ was starting on %1$@, so the start stopped. Run `%3$@` again in the account you want it in.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    // MARK: The start (``CloudStartSession``)

    /// A non-person run that names no machine.
    public static func needsMachine(agent: String) -> String {
        String(format: String(localized: "cloud.startSession.needsMachine", defaultValue: "Say which Cloud machine to start %1$@ on: `cmux cloud start-session --target machine:<id> --agent %1$@`, or `--name <name>` to take that machine or create it. `cmux cloud list-machines` lists your machines.", table: "CloudSessions", bundle: .localizedModule), agent)
    }

    /// Cloud first use refused the run (``CloudSetup/refusal(harness:model:)``, as the composer's Set up Cloud card): no
    /// connection on this Mac or the team serves `agent`'s family, so no machine was taken. `link` opens the Settings >
    /// Cloud row that sets it up (`cmux://settings/cloud/claude` or `/chatgpt`, the running build's scheme). With
    /// `localLogin` (a Claude Code or Codex login on this Mac, which serves only this Mac) it says why that one does not count.
    /// `gatewayTeam`, `gatewayCode`: the team gateway the refusal read and why it counted none (the CLI's error code, or
    /// `not_serving` when it read the gateway off or offline), said last (hq#19758); nil when none was read.
    public static func setupRequired(agent: String, family: String, localLogin: Bool, link: String, command: String,
                                     gatewayTeam: String? = nil, gatewayCode: String? = nil) -> String {
        let text = String(format: String(localized: "cloud.startSession.setupRequired", defaultValue: "No Cloud connection serves %1$@ yet. Add one in Settings > Cloud (ChatGPT, Claude or an API key), then run `%2$@` again.", table: "CloudSessions", bundle: .localizedModule), agent, command)
        var open = String(format: String(localized: "cloud.startSession.setupRequired.open", defaultValue: "`cmux link open --url %@` opens it there.", table: "CloudSessions", bundle: .localizedModule), link)
        if let gatewayCode {
            open += " " + String(format: String(localized: "cloud.startSession.setupRequired.gateway", defaultValue: "Inference gateway of team %1$@: %2$@.", table: "CloudSessions", bundle: .localizedModule), gatewayTeam ?? "-", gatewayCode)
        }
        guard localLogin else { return text + " " + open }
        let login = family == "codex"
            ? String(localized: "cloud.startSession.setupRequired.codexLogin", defaultValue: "Your Codex login on this Mac works only on this Mac; Cloud needs a ChatGPT connection (or an API key).", table: "CloudSessions", bundle: .localizedModule)
            : String(localized: "cloud.startSession.setupRequired.claudeLogin", defaultValue: "Your Claude Code login on this Mac works only on this Mac; Cloud needs a Claude setup token (or an API key).", table: "CloudSessions", bundle: .localizedModule)
        return login + " " + text + " " + open
    }

    public static func noSuchMachine(id: String, agent: String) -> String {
        String(format: String(localized: "cloud.startSession.noSuchMachine", defaultValue: "No Cloud machine `%1$@` is listed on this Mac. `cmux cloud list-machines` lists them, and `cmux cloud start-session --name <name> --agent %2$@` creates one.", table: "CloudSessions", bundle: .localizedModule), id, agent)
    }

    public static var agentInvalid: String {
        String(localized: "cloud.startSession.agentInvalid", defaultValue: "Pass the agent to start with --agent, for example `cmux cloud start-session --name dev --agent claude`.", table: "CloudSessions", bundle: .localizedModule)
    }

    public static var cwdInvalid: String {
        String(localized: "cloud.startSession.cwdInvalid", defaultValue: "Pass --cwd as an absolute folder on the machine, for example `cmux cloud start-session --target machine:<id> --agent claude --cwd /home/cmux/FOLDER`.", table: "CloudSessions", bundle: .localizedModule)
    }

    // `--from-folder`: a folder on this Mac copied to the machine (``CloudStartSession`` +Folder).
    public static var fromFolderWithCwd: String {
        String(localized: "cloud.startSession.fromFolderWithCwd", defaultValue: "Pass --from-folder or --cwd, not both: with --from-folder the session starts in the folder's copy on the machine.", table: "CloudSessions", bundle: .localizedModule)
    }

    public static func fromFolderNotOwned(_ machine: String) -> String {
        String(format: String(localized: "cloud.startSession.fromFolderNotOwned", defaultValue: "%@ isn't your own machine, so no folder from this Mac was copied to it. Copy a folder only to a Cloud machine you own.", table: "CloudSessions", bundle: .localizedModule), machine)
    }

    public static var fromFolderInvalid: String {
        String(localized: "cloud.startSession.fromFolderInvalid", defaultValue: "Pass --from-folder as an absolute folder on this Mac, for example `cmux cloud start-chat --from-folder /Users/me/code/app --prompt 'Run the tests'`.", table: "CloudSessions", bundle: .localizedModule)
    }

    public static func fromFolderMissing(_ folder: String) -> String {
        String(format: String(localized: "cloud.startSession.fromFolderMissing", defaultValue: "%@ isn't a folder on this Mac, so nothing was copied. Pass an existing folder with --from-folder.", table: "CloudSessions", bundle: .localizedModule), folder)
    }

    public static func fromFolderTooBroad(_ folder: String) -> String {
        String(format: String(localized: "cloud.startSession.fromFolderTooBroad", defaultValue: "%@ is your home folder, a folder above it or the disk's root, which is never copied to a Cloud machine. Pass a project folder with --from-folder.", table: "CloudSessions", bundle: .localizedModule), folder)
    }

    public static func fromFolderSecret(_ folder: String, secret: String) -> String {
        String(format: String(localized: "cloud.startSession.fromFolderSecret", defaultValue: "%1$@ is or holds %2$@, a folder of keys and credentials that is never copied to a Cloud machine. Pass a project folder with --from-folder.", table: "CloudSessions", bundle: .localizedModule), folder, secret)
    }

    /// Why a create was refused for its size (``CloudSizeLocked``), as ``createFailed(_:quoted:agent:reason:)``'s reason: the
    /// size the folder needs and the plan that includes it; nil when the size it needed is not known.
    public static func sizeLocked(_ locked: CloudSizeLocked) -> String? {
        guard let size = locked.needed else { return nil }
        let (name, cpu, memory) = (size.rawValue, String(size.cpu), String(size.memoryMb / 1024))
        guard let plan = locked.upgrade else {
            return String(format: String(localized: "cloud.startSession.sizeLockedNoUpgrade", defaultValue: "this folder needs a %1$@ machine (%2$@ vCPU, %3$@ GB memory), larger than your plan includes", table: "CloudSessions", bundle: .localizedModule), name, cpu, memory)
        }
        // The words after "cmux": product names, never translated.
        let words = switch plan {
        case "max": "Max"
        case "next_plus": "NEXT Plus"
        case "next_pro": "NEXT Pro"
        case "next_max": "NEXT Max"
        default: "Pro"
        }
        return String(format: String(localized: "cloud.startSession.sizeLocked", defaultValue: "this folder needs a %1$@ machine (%2$@ vCPU, %3$@ GB memory), which your plan doesn't include. Upgrade to cmux %4$@ to use one", table: "CloudSessions", bundle: .localizedModule), name, cpu, memory, words)
    }

    /// The machine to create (`--name`) could not be created; `reason` says why. `quoted` is the
    /// name as one shell word for the command.
    public static func createFailed(_ name: String, quoted: String, agent: String, reason: String) -> String {
        String(format: String(localized: "cloud.startSession.createFailed", defaultValue: "Couldn't create Cloud machine `%1$@` (%4$@), so no agent started. Run `cmux cloud start-session --name %2$@ --agent %3$@` again, or pick a machine from `cmux cloud list-machines`.", table: "CloudSessions", bundle: .localizedModule), name, quoted, agent, reason)
    }

    public static func notConnected(_ name: String, id: String, agent: String) -> String {
        String(format: String(localized: "cloud.startSession.notConnected", defaultValue: "Machine `%1$@` didn't connect, so no agent started there. Check it with `cmux cloud machine-status --target machine:%2$@`, then run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again.", table: "CloudSessions", bundle: .localizedModule), name, id, agent)
    }

    /// A failed start could not delete the machine it made for itself: it still runs, and the command deletes it.
    public static func newMachineKept(_ name: String, id: String) -> String {
        String(format: String(localized: "cloud.startSession.newMachineKept", defaultValue: "Its new machine `%1$@` still runs. Delete it with `cmux cloud kill-machine --target machine:%2$@ --confirm true`.", table: "CloudSessions", bundle: .module), name, id)
    }

    /// The person closed the new chat's tab before its session started.
    public static func tabClosed(_ name: String, id: String, agent: String) -> String {
        String(format: String(localized: "cloud.startSession.tabClosed", defaultValue: "The new chat's tab on machine `%1$@` was closed before its agent started, so %3$@ didn't start there. Run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again.", table: "CloudSessions", bundle: .localizedModule), name, id, agent)
    }

    /// The machine is up and the start was refused; `reason` is the refusal in plain words.
    public static func agentFailed(_ name: String, id: String, agent: String, reason: String) -> String {
        String(format: String(localized: "cloud.startSession.agentFailed", defaultValue: "Machine `%1$@` started but its agent didn't (%4$@). Run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again.", table: "CloudSessions", bundle: .localizedModule), name, id, agent, reason)
    }

    /// The machine is up and its agent is not signed in there (`agent_session.sign_in_required`,
    /// hq#11225); `agentName` is the agent as a person reads it (Cursor). `expired`: its sign-in there expired.
    public static func agentSignedOut(_ name: String, id: String, agent: String, agentName: String, expired: Bool) -> String {
        expired
            ? String(format: String(localized: "cloud.startSession.agentSignInExpired", defaultValue: "Machine `%1$@` started, but %4$@'s sign-in expired on that machine. Sign it in again there, then run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again.", table: "CloudSessions", bundle: .localizedModule), name, id, agent, agentName)
            : String(format: String(localized: "cloud.startSession.agentSignedOut", defaultValue: "Machine `%1$@` started, but %4$@ isn't signed in on that machine. Sign it in there, then run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again.", table: "CloudSessions", bundle: .localizedModule), name, id, agent, agentName)
    }

    /// The `agent-session-start` refusals that name their cause (cmux-tui agent_session_start.rs, hq#11225): an agent
    /// not signed in, an agent the machine lacks, a model route that can't serve the start.
    public static let namedRefusals: Set<String> = ["agent_session.sign_in_required", "agent_session.harness_missing", "agent_session.route_unavailable"]

    /// A named refusal (`namedRefusals`) in the run's words. `agentName`: the agent as a person reads it; `expired`:
    /// its sign-in expired; `harness`: the refused harness id (`cmux`, the cmux router, is named as the router).
    public static func namedRefusal(_ code: String, _ name: String, id: String, agent: String, agentName: String, expired: Bool, harness: String) -> String {
        switch code {
        case "agent_session.harness_missing": agentMissing(name, id: id, agent: agent, agentName: agentName)
        case "agent_session.route_unavailable": routeUnavailable(name, id: id, agent: agent, agentName: agentName, router: harness == "cmux")
        default: agentSignedOut(name, id: id, agent: agent, agentName: agentName, expired: expired)
        }
    }

    /// The machine is up and the agent isn't installed there (`agent_session.harness_missing`, hq#11225);
    /// `agentName` is the agent as a person reads it (Cursor).
    public static func agentMissing(_ name: String, id: String, agent: String, agentName: String) -> String {
        String(format: String(localized: "cloud.startSession.agentMissing", defaultValue: "Machine `%1$@` started, but %4$@ (`%3$@`) isn't installed on that machine. Install it there, or run `cmux cloud start-session --target machine:%2$@ --agent AGENT` with another agent.", table: "CloudSessions", bundle: .localizedModule), name, id, agent, agentName)
    }

    /// The machine is up and the agent's model route can't serve it there (`agent_session.route_unavailable`,
    /// hq#11225). `router`: the agent is the cmux router, named as the router.
    public static func routeUnavailable(_ name: String, id: String, agent: String, agentName: String, router: Bool) -> String {
        router
            ? String(format: String(localized: "cloud.startSession.routerUnavailable", defaultValue: "Machine `%1$@` started, but the cmux router isn't available on that machine. Run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again later, or pick another agent.", table: "CloudSessions", bundle: .localizedModule), name, id, agent)
            : String(format: String(localized: "cloud.startSession.routeUnavailable", defaultValue: "Machine `%1$@` started, but %4$@'s model route isn't available on that machine. Run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again later, or pick another agent.", table: "CloudSessions", bundle: .localizedModule), name, id, agent, agentName)
    }

    /// The start found no folder it may use (none in the workspace, or the home folder).
    public static func needsFolder(_ name: String, id: String, agent: String) -> String {
        String(format: String(localized: "cloud.startSession.needsFolder", defaultValue: "Machine `%1$@` started but its agent didn't: it needs a folder on that machine to start in. Run `cmux cloud start-session --target machine:%2$@ --agent %3$@ --cwd FOLDER` again with a folder that exists there.", table: "CloudSessions", bundle: .localizedModule), name, id, agent)
    }

    // MARK: The card's text and what an agent's run says

    public static func ask(agent: String, machine: String) -> String {
        String(format: String(localized: "cloud.startSession.ask", defaultValue: "The agent asks to start a %1$@ session on Cloud machine %2$@.", table: "CloudSessions", bundle: .localizedModule), agent, machine)
    }

    public static func askNew(agent: String, machine: String) -> String {
        String(format: String(localized: "cloud.startSession.askNew", defaultValue: "The agent asks to create Cloud machine %2$@ and start a %1$@ session there.", table: "CloudSessions", bundle: .localizedModule), agent, machine)
    }

    public static func starting(agent: String, machine: String) -> String {
        String(format: String(localized: "cloud.startSession.starting", defaultValue: "Starting %1$@ on %2$@…", table: "CloudSessions", bundle: .localizedModule), agent, machine)
    }

    /// The card once the session runs: it links the asking chat to the new one.
    public static func started(agent: String, machine: String) -> String {
        String(format: String(localized: "cloud.startSession.started", defaultValue: "%1$@ runs on Cloud machine %2$@. Its chat is in that machine's workspace in the sidebar.", table: "CloudSessions", bundle: .localizedModule), agent, machine)
    }

    /// Open Chat on that card when no connected machine lists the new chat any more.
    public static func chatGone(agent: String, machine: String) -> String {
        String(format: String(localized: "cloud.startSession.chatGone", defaultValue: "Couldn't open the %1$@ chat on %2$@: its tab was closed or the machine isn't connected.", table: "CloudSessions", bundle: .localizedModule), agent, machine)
    }

    /// A run that answered `pending`: the same command again answers its end.
    public static func stillStarting(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.stillStarting", defaultValue: "%2$@ is still starting on %1$@. Run `%3$@` again to get its machine_id and session_id.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    // MARK: The ask as a dialog (``CloudAskDialogs``)

    /// An agent's run once its card asks: it answers at once, naming the dialog and how to answer it.
    public static func askPending(_ asked: Asked, dialog: String) -> String {
        String(format: String(localized: "cloud.startSession.askPending", defaultValue: "Asked the person in this chat to start %2$@ on %1$@ (Start or Not now, for 2 minutes). Run `%3$@` again to wait for their answer and get machine_id and session_id. They can also answer from their own terminal: `cmux agents dialog answer %4$@ --selection start`.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command, dialog)
    }

    /// An agent's Start on an ask the person did not delegate.
    public static func personRequired(_ dialog: String) -> String {
        String(format: String(localized: "cloud.startSession.personRequired", defaultValue: "Only the person can choose Start: on the card in the chat, or with `cmux agents dialog answer %1$@ --selection start` in their own terminal. To let agents start Cloud sessions without asking, they can turn on Let Agents Use Cloud Without Asking in Settings > Machines. `--selection notNow` declines.", table: "CloudSessions", bundle: .localizedModule), dialog)
    }

    public static func unknownChoice(_ dialog: String) -> String {
        String(format: String(localized: "cloud.startSession.unknownChoice", defaultValue: "Answer %1$@ with `--selection start` or `--selection notNow`.", table: "CloudSessions", bundle: .localizedModule), dialog)
    }

    public static func dialogGone(_ dialog: String) -> String {
        String(format: String(localized: "cloud.startSession.dialogGone", defaultValue: "No Cloud start %1$@ waits for an answer: it was answered, timed out or ended. `cmux agents dialog list` shows what still waits.", table: "CloudSessions", bundle: .localizedModule), dialog)
    }

    public static func notInChat(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.notInChat", defaultValue: "Couldn't find the chat this agent runs in, so nobody can be asked to start %2$@ on Cloud machine %1$@. Run `%3$@` from an agent's shell in a cmux chat, or ask the person to run it.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    public static func targetUnread(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.targetUnread", defaultValue: "Couldn't read the Cloud machines of the account signed in now, so %2$@ didn't start on %1$@. Check `cmux cloud list-machines`, then run `%3$@` again.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }

    public static func listUnread(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.listUnread", defaultValue: "Couldn't read your Cloud machines, so %2$@ didn't start: a machine named %1$@ may already exist. Check `cmux cloud list-machines`, then run `%3$@` again.", table: "CloudSessions", bundle: .localizedModule), asked.machine, asked.agent, asked.command)
    }
}
