import Foundation

/// What `cmux cloud start-session` says (``CloudStartSessionAsks``): an agent's ask in its chat,
/// and why it stopped. Each refusal names the machine and the agent and gives the command to run
/// again. Keys live in Resources/CloudSessions.xcstrings with every app locale.
enum CloudStartSessionStrings {
    /// What a refusal of an agent's ask names: the machine, the agent and the command to run again.
    struct Asked: Equatable {
        var machine: String
        var agent: String
        var command: String
    }

    static var start: String { String(localized: "cloud.startSession.start", defaultValue: "Start", table: "CloudSessions", bundle: .module) }

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

    /// The signed-in account or team changed while the ask or its run waited.
    static func accountChanged(_ asked: Asked) -> String {
        String(format: String(localized: "cloud.startSession.accountChanged", defaultValue: "Your Cloud account or team changed after this was asked, so %2$@ didn't start on %1$@. Run `%3$@` again in the account you want it in.", table: "CloudSessions", bundle: .module), asked.machine, asked.agent, asked.command)
    }
}
