import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextHostedChief
import CmuxNextRemote
import Foundation

/// Which brain answers a Home Chief conversation, and the owner's control
/// of it: the engine source of the settings panel and `chief.stop`. This
/// Mac's Chief goes through this Mac's Chief owner daemon (which forwards to
/// its brain's tools socket); a cloud Chief placed on a paired server goes
/// through that server's daemon (the owner session the app holds); a hosted
/// cloud Chief (no `brain_place`) through the Cloud service's brain route.
@MainActor
struct HomeChiefControl {
    let services: AppServices
    let conversation: ConversationID
    /// The default Chief's mux home (this build's Chief home).
    let muxHome: URL
    /// The local Chief this conversation is with when it is not the default
    /// (chief-brains-v1, cx-327wl): every control names it in `chief`, so the
    /// panel, Stop and the avatar act on that Chief's own brain, never the
    /// default's. Nil: the default Chief (or a cloud Chief).
    var chief: String?

    /// The `shared stop action` (palette, the compose bar's stop button, Esc
    /// and Cmd-. in the field): the key window's Home view stops its Chief.
    static let stopAction: ActionID = "home.stopChief"
    /// Stop all agents (the menu, the palette, Option-click on the stop
    /// button): the front window's Chief Home stops its Chief's turn and
    /// every subagent, and its toast offers Restart (HomeHostView+StopAll).
    static let stopAllAction: ActionID = "home.stopAllAgents"

    var isCloud: Bool { services.home.isCloudConversation(conversation) }

    /// A cloud Chief no paired server runs: the Cloud service's brain answers. A cloud Chief
    /// not listed yet counts as hosted (a new Chief); the list's answer picks again.
    var isHosted: Bool { isCloud && services.home.cloudChiefPlacement(of: conversation.rawValue)?.placed != true }

    /// The hosted Chief's agent id; nil while it is not listed (or a server runs it).
    var hostedChiefID: String? {
        isCloud ? services.home.cloudChiefPlacement(of: conversation.rawValue).flatMap { $0.placed ? nil : $0.id } : nil
    }

    /// The paired server that runs this cloud Chief's brain (`brain_place`).
    var server: ServerMachineSession? {
        guard isCloud, let host = services.home.cloudChiefs.chief(for: conversation.rawValue)?.brainPlace?.host else { return nil }
        return services.machines.servers.first { $0.reach.hostID == host }
    }

    /// The daemon in front of the brain; nil while it is not connected.
    var connection: DaemonConnection? {
        isCloud ? server?.daemon.connection : services.home.connection
    }

    /// The `chief` field of this conversation's controls: a local Chief that
    /// is not the default; nil for the default and a cloud Chief.
    var named: String? { isCloud ? nil : chief }

    /// The mux home of the brain that answers here (ChiefHome.brainHome).
    var brainHome: URL { ChiefHome.brainHome(muxHome: muxHome, chief: named) }

    /// The settings panel's source for this Chief.
    func engineSource() -> any HomeChiefEngineSource {
        let files = HomeChiefFiles(muxHome: brainHome)
        let services = services
        guard isCloud else {
            // The owner daemon starts a named Chief's brain (chief_brains.rs);
            // only the default Chief's host is this app's to start.
            let named = named
            return HomeChiefLocalEngine(files: files, connection: { [weak services] in services?.home.connection },
                                        startBrain: { [weak services] asked in
                                            named == nil ? services?.home.brain.ensure(asked: asked) ?? false : false
                                        }, chief: named)
        }
        let conversation = conversation
        let muxHome = muxHome
        if isHosted {
            return HomeChiefHostedEngine(
                chief: { HomeChiefControl(services: services, conversation: conversation, muxHome: muxHome).hostedChiefID },
                send: services.home.hostedChief.brainRoute, files: files)
        }
        return HomeChiefRemoteEngine(
            connection: { HomeChiefControl(services: services, conversation: conversation, muxHome: muxHome).connection },
            place: server?.name ?? services.home.cloudChiefs.chief(for: conversation.rawValue)?.brainPlace?.host,
            files: files)
    }

    var turnControl: HomeChiefTurnControl {
        HomeChiefTurnControl(connection: connection, named: named, isHosted: isHosted)
    }
    func stop() async -> HomeChiefEngineError? { await turnControl.stop() }
    func stopAll() async -> Result<ChiefStopAll, HomeChiefEngineError> { await turnControl.stopAll() }
    func restart(_ names: [String]) async -> HomeChiefEngineError? { await turnControl.restart(names) }

}

/// The stop-all toast's words. Keys live in Resources/Localizable.xcstrings.
enum HomeStopAllStrings {
    static var stopToolTip: String {
        String(localized: "home.stop.toolTip", defaultValue: "Stop the Chief (Option-click: Stop All Agents)", bundle: .module)
    }
    static var restart: String { String(localized: "home.stopAll.restart", defaultValue: "Restart", bundle: .module) }
    static var stoppedNone: String {
        String(localized: "home.stopAll.none", defaultValue: "No agents were running", bundle: .module)
    }
    static var stoppedChiefOnly: String {
        String(localized: "home.stopAll.chiefOnly", defaultValue: "Stopped the Chief; no subagents were running", bundle: .module)
    }
    /// Why Stop All Agents is unavailable: the key window shows no Chief's Home.
    static var unavailable: String {
        String(localized: "home.stopAll.unavailable", defaultValue: "Stop All Agents works in a Chief's Home", bundle: .module)
    }
    /// "Stopped the Chief": its turn stopped, no subagent did, and some could not be stopped.
    static var stoppedChief: String {
        String(localized: "home.stopAll.chiefStopped", defaultValue: "Stopped the Chief", bundle: .module)
    }
    /// How many subagents acpmux refused to stop; which ones and why are the toast's detail.
    static func couldNotStop(_ count: Int) -> String {
        String(localized: "home.stopAll.couldNotStop", defaultValue: "\(count) could not be stopped", bundle: .module)
    }
    /// The toast after Stop all agents: the subagents it stopped (else whether the Chief's
    /// turn stopped), how many could not be stopped, and the daemon's note about any still
    /// starting. One short line each; the count goes before the note, which is cut first when
    /// the list of stopped subagents wraps (the tooltip repeats it).
    static func message(for answer: ChiefStopAll) -> String {
        var lines: [String] = []
        if !answer.subagents.isEmpty {
            lines.append(stopped(answer.subagents))
        } else if answer.errors.isEmpty {
            lines.append(answer.stopped ? stoppedChiefOnly : stoppedNone)
        } else if answer.stopped {
            lines.append(stoppedChief)
        }
        if !answer.errors.isEmpty { lines.append(couldNotStop(answer.errors.count)) }
        if let note = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { lines.append(note) }
        return lines.joined(separator: "\n")
    }
    /// The toast's tooltip: one line per subagent that could not be stopped, as the daemon
    /// wrote it (the subagent and acpmux's error), then the note, so a note the toast's three
    /// lines cut off (a long list of stopped subagents) can still be read; nil with neither.
    static func detail(for answer: ChiefStopAll) -> String? {
        let lines = (answer.errors + [answer.note].compactMap { $0 })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    static func stopped(_ names: [String]) -> String {
        String(format: String(localized: "home.stopAll.stopped", defaultValue: "Stopped all agents: %@", bundle: .module),
               ListFormatter.localizedString(byJoining: names))
    }
}
