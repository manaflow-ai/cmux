import Foundation

/// What `cmux cloud start-session` says (``CloudStartSession``). Each failure names the machine
/// and the agent and gives the command to run next. Keys live in Resources/CloudSessions.xcstrings
/// with every app locale. `%1$@` is the machine's name, `%2$@` its id, `%3$@` the agent.
enum CloudStartSessionStrings {
    /// A non-person run that names no machine.
    static func needsMachine(agent: String) -> String {
        String(format: String(localized: "cloud.startSession.needsMachine", defaultValue: "Say which Cloud machine to start %1$@ on: `cmux cloud start-session --target machine:<id> --agent %1$@`, or `--name <name>` to take that machine or create it. `cmux cloud list-machines` lists your machines.", table: "CloudSessions", bundle: .module), agent)
    }

    static func noSuchMachine(id: String, agent: String) -> String {
        String(format: String(localized: "cloud.startSession.noSuchMachine", defaultValue: "No Cloud machine `%1$@` is listed on this Mac. `cmux cloud list-machines` lists them, and `cmux cloud start-session --name <name> --agent %2$@` creates one.", table: "CloudSessions", bundle: .module), id, agent)
    }

    static var agentInvalid: String {
        String(localized: "cloud.startSession.agentInvalid", defaultValue: "Pass the agent to start with --agent, for example `cmux cloud start-session --name dev --agent claude`.", table: "CloudSessions", bundle: .module)
    }

    static var cwdInvalid: String {
        String(localized: "cloud.startSession.cwdInvalid", defaultValue: "Pass --cwd as an absolute folder on the machine, for example `cmux cloud start-session --target machine:<id> --agent claude --cwd /home/cmux/work`.", table: "CloudSessions", bundle: .module)
    }

    /// The machine to create (`--name`) could not be created; `reason` says why. `quoted` is the
    /// name as one shell word for the command.
    static func createFailed(_ name: String, quoted: String, agent: String, reason: String) -> String {
        String(format: String(localized: "cloud.startSession.createFailed", defaultValue: "Couldn't create Cloud machine `%1$@` (%4$@), so no agent started. Run `cmux cloud start-session --name %2$@ --agent %3$@` again, or pick a machine from `cmux cloud list-machines`.", table: "CloudSessions", bundle: .module), name, quoted, agent, reason)
    }


    static func notConnected(_ name: String, id: String, agent: String) -> String {
        String(format: String(localized: "cloud.startSession.notConnected", defaultValue: "Machine `%1$@` didn't connect, so no agent started there. Check it with `cmux cloud machine-status --target machine:%2$@`, then run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again.", table: "CloudSessions", bundle: .module), name, id, agent)
    }

    /// The machine is up and the start was refused; `reason` is the refusal in plain words.
    static func agentFailed(_ name: String, id: String, agent: String, reason: String) -> String {
        String(format: String(localized: "cloud.startSession.agentFailed", defaultValue: "Machine `%1$@` started but its agent didn't (%4$@). Run `cmux cloud start-session --target machine:%2$@ --agent %3$@` again.", table: "CloudSessions", bundle: .module), name, id, agent, reason)
    }

    /// The start found no folder it may use (none in the workspace, or the home folder).
    static func needsFolder(_ name: String, id: String, agent: String) -> String {
        String(format: String(localized: "cloud.startSession.needsFolder", defaultValue: "Machine `%1$@` started but its agent didn't: it needs a folder on that machine to start in. Run `cmux cloud start-session --target machine:%2$@ --agent %3$@ --cwd /home/cmux/work` again with a folder there.", table: "CloudSessions", bundle: .module), name, id, agent)
    }

    // MARK: An agent's ask in its chat

    static func ask(agent: String, machine: String) -> String {
        String(format: String(localized: "cloud.startSession.ask", defaultValue: "The agent asks to start a %1$@ session on Cloud machine %2$@.", table: "CloudSessions", bundle: .module), agent, machine)
    }

    static func askNew(agent: String, machine: String) -> String {
        String(format: String(localized: "cloud.startSession.askNew", defaultValue: "The agent asks to create Cloud machine %2$@ and start a %1$@ session there.", table: "CloudSessions", bundle: .module), agent, machine)
    }

    static func starting(agent: String, machine: String) -> String {
        String(format: String(localized: "cloud.startSession.starting", defaultValue: "Starting %1$@ on %2$@…", table: "CloudSessions", bundle: .module), agent, machine)
    }

    static var start: String { String(localized: "cloud.startSession.start", defaultValue: "Start", table: "CloudSessions", bundle: .module) }

    /// What a refusal of an agent's ask names: the machine, the agent and the command to run again.
    struct Asked: Equatable {
        var machine: String
        var agent: String
        var command: String
    }

    /// A run that answered `pending`: the same command again answers its end.
    static func stillStarting(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.stillStarting", defaultValue: "%2$@ is still starting on %1$@. Run `%3$@` again to get its machine_id and session_id.", table: "CloudSessions", bundle: .module), asked.machine, asked.agent, asked.command)
    }

    static func notInChat(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.notInChat", defaultValue: "Couldn't find the chat this agent runs in, so nobody can be asked to start %2$@ on Cloud machine %1$@. Run `%3$@` from an agent's shell in a cmux chat, or ask the person to run it.", table: "CloudSessions", bundle: .module), asked.machine, asked.agent, asked.command)
    }

    static func noPage(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.noPage", defaultValue: "Couldn't show the question in the chat, so %2$@ didn't start on %1$@. Run `%3$@` again once the chat is open.", table: "CloudSessions", bundle: .module), asked.machine, asked.agent, asked.command)
    }

    static func askOpen(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.askOpen", defaultValue: "This chat already asks the person to start a Cloud session. Wait for their answer, then run `%3$@` again if %2$@ still isn't running on %1$@.", table: "CloudSessions", bundle: .module), asked.machine, asked.agent, asked.command)
    }

    static func declined(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.declined", defaultValue: "The person chose Not now, so %2$@ didn't start on %1$@. Ask them in the chat before you run `%3$@` again.", table: "CloudSessions", bundle: .module), asked.machine, asked.agent, asked.command)
    }

    static func expired(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.expired", defaultValue: "Nobody answered the question in the chat within 2 minutes, so %2$@ didn't start on %1$@. Run `%3$@` again when the person is there.", table: "CloudSessions", bundle: .module), asked.machine, asked.agent, asked.command)
    }

    /// The machine list could not be read, so a machine by that name may exist.
    static func listUnread(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.listUnread", defaultValue: "Couldn't read your Cloud machines, so %2$@ didn't start: a machine named %1$@ may already exist. Check `cmux cloud list-machines`, then run `%3$@` again.", table: "CloudSessions", bundle: .module), asked.machine, asked.agent, asked.command)
    }
}
