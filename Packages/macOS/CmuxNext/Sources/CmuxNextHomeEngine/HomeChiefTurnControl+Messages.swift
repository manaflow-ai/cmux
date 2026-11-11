public import CmuxNextHome
import CmuxNextDaemon

/// The Messages page's Stop, Stop all agents, Continue, Restart and a queued agent's Start now (``HomeMessagesChiefTurn``) on
/// this captured Chief route, as the native compose button and toast ran them.
extension HomeChiefTurnControl: HomeMessagesChiefControl {
    public func stopTurn() async -> Result<Bool, HomeMessagesChiefRefusal> {
        await stopResult().mapError { HomeMessagesChiefRefusal($0.text) }
    }

    public func stopAllAgents() async -> Result<HomeChiefStopAllAnswer, HomeMessagesChiefRefusal> {
        await stopAll()
            .map { HomeChiefStopAllAnswer(stopped: $0.stopped, subagents: $0.subagents, errors: $0.errors, note: $0.note) }
            .mapError { HomeMessagesChiefRefusal($0.text) }
    }

    public func continueStoppedTurn() async -> Result<(continued: Bool, reason: String?), HomeMessagesChiefRefusal> {
        await continueTurn().map { (continued: $0.continued == true, reason: $0.reason) }.mapError { HomeMessagesChiefRefusal($0.text) }
    }

    public func restartAgents(_ names: [String]) async -> HomeMessagesChiefRefusal? {
        await restart(names).map { HomeMessagesChiefRefusal($0.text) }
    }

    public func startQueuedAgent(_ name: String) async -> HomeMessagesChiefRefusal? {
        await startNow(name).map { HomeMessagesChiefRefusal($0.text) }
    }

    public func slashSkills() async -> Result<[HomeChiefSlashSkill]?, HomeMessagesChiefRefusal> {
        await offeredSkills()
            .map { $0?.map { HomeChiefSlashSkill(name: $0.name, description: $0.description, source: $0.source) } }
            .mapError { HomeMessagesChiefRefusal($0.text) }
    }
}
