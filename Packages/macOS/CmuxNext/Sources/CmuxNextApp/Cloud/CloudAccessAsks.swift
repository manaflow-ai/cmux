import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// A moved chat's file requests for this Mac (cmuxterm-hq#1874 slice 6): while chats a move put on
/// a connected Cloud machine (``CloudMovedChats``) exist, the app runs `cmux link access triage`
/// for each machine's chats every ``CloudMoveSetup/accessPoll`` (one run at a time), which answers
/// what needs no person, and shows each file ask left as a card in that chat's tab on the machine
/// (``AgentToolCards``, never a sheet): Allow once, Always for its folder, Deny. Only the person's
/// click (a real gesture in the pane, ``AgentPaneToolCard``) answers, with exactly what the card
/// showed; nothing is answered from the ask's own `exists` or `shareable`. The chat's granted
/// folders are copied again every ``CloudMoveSetup/accessSync``, and Bring Back Local ends its
/// grants (``chatBroughtBack(machineID:session:services:)``).
///
/// The ask's text comes from the machine (its path and reason); the card names the machine, not
/// the chat, as the asker, since the session an ask names is the machine's claim. Only asks of the
/// sessions this Mac moved there are shown, each in that session's own tab.
@MainActor
final class CloudAccessAsks {
    /// The cards' owner in ``AgentToolCards``.
    static let owner = "cloudAccess"

    private enum Action: String {
        case allow, always, deny
    }

    /// One ask shown on a card, with what answering it names.
    private struct Shown: Equatable {
        var ask: CloudAccessCLI.FileAsk
        /// The chat's session on the machine, from the ledger (the ask's own matched it).
        var session: String
        var machineID: String
        var machineName: String
        var socket: String
        var remoteRoot: String
        var card: String { "cloud-access-" + ask.requestID }
    }

    private var loop: Task<Void, Never>?
    /// The asks shown, by chat tab.
    private var shown: [String: [Shown]] = [:]
    /// Requests whose answer is running.
    private var answering: Set<String> = []
    /// Requests answered, with the triage count when their answer ended: a triage that began by then
    /// may still list them, so it shows them no more.
    private var answered: [String: Int] = [:]
    private var triages = 0
    private var lastSync: [String: ContinuousClock.Instant] = [:]

    /// Starts polling; it ends with this object or `services`.
    func start(services: AppServices) {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self, weak services] in
            while !Task.isCancelled {
                guard let pause = await self?.poll(services) else { return }
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// Bring Back Local moved chat `session` off machine `machineID`: its grants there end. A
    /// failure is logged, never the bring back's.
    func chatBroughtBack(machineID: String, session: String, services: AppServices) {
        guard let binary = services.cloud.move.cli else { return }
        let logger = services.cloud.logger
        Task { @MainActor [weak services] in
            let socket = await services?.machines.session(machineID)?.daemon.connection?.endpoint?.socketPath
            do {
                let answer = try await CloudAccessCLI(binary: binary).revoke(socket: socket, machine: machineID, session: session)
                if !answer.ok { logger.error("cloud access revoke: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .public)") }
            } catch {
                logger.error("cloud access revoke: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// One round over the machines; how long to wait before the next, nil once `services` is gone.
    private func poll(_ services: AppServices?) async -> Duration? {
        guard let services else { return nil }
        let setup = services.cloud.move
        let chats = services.cloud.movedChats.all().filter { $0.broughtBack == nil }
        guard let binary = setup.cli, !chats.isEmpty else {
            show([:], services: services)
            return setup.accessPoll
        }
        triages += 1
        let triage = triages
        let cli = CloudAccessCLI(binary: binary)
        var next: [String: [Shown]] = [:]
        for (machineID, machineChats) in Dictionary(grouping: chats, by: \.machineID).sorted(by: { $0.key < $1.key }) {
            guard let machine = services.machines.session(machineID), let socket = await machine.daemon.connection?.endpoint?.socketPath else { continue }
            if lastSync[machineID].map({ $0.duration(to: .now) >= setup.accessSync }) ?? true {
                lastSync[machineID] = .now
                await sync(cli, socket: socket, machine: machineID, services: services)
            }
            let answer: CloudAccessCLI.Answer
            do {
                answer = try await cli.triage(socket: socket, machine: machineID, sessions: Array(Set(machineChats.map(\.session))).sorted())
            } catch {
                answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
            }
            guard answer.ok else {
                services.cloud.logger.error("cloud access triage: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .public)")
                // Keep this machine's cards as they were; the next round asks again.
                for (tab, asks) in shown where asks.contains(where: { $0.machineID == machineID }) { next[tab] = asks }
                continue
            }
            if answer.failures > 0 { services.cloud.logger.error("cloud access triage: \(answer.failures) requests failed") }
            for ask in answer.asks where !answering.contains(ask.requestID) && answered[ask.requestID].map({ triage > $0 }) ?? true {
                guard let chat = machineChats.first(where: { $0.session == ask.session }), let tab = Self.tab(of: chat, on: machine, services: services),
                      let root = Self.remoteRoot(chat.remoteFolder, roots: setup.workRoots) else { continue }
                answered[ask.requestID] = nil
                next[tab, default: []].append(Shown(ask: ask, session: chat.session, machineID: machineID, machineName: machine.machine.title, socket: socket, remoteRoot: root))
            }
        }
        answered = answered.filter { $0.value >= triage }
        show(next, services: services)
        return setup.accessPoll
    }

    private func sync(_ cli: CloudAccessCLI, socket: String, machine: String, services: AppServices) async {
        do {
            let answer = try await cli.sync(socket: socket, machine: machine)
            if !answer.ok || answer.failures > 0 {
                services.cloud.logger.error("cloud access sync: \(answer.errorCode ?? "", privacy: .public) \(answer.failures) copies failed")
            }
        } catch {
            services.cloud.logger.error("cloud access sync: \(String(describing: error), privacy: .public)")
        }
    }

    /// Shows `next` (by tab), at most ``AgentPaneToolCard/maximumShown`` per chat, and removes the
    /// cards of tabs it no longer has.
    private func show(_ next: [String: [Shown]], services: AppServices) {
        for tab in Set(shown.keys).union(next.keys) {
            let asks = Array((next[tab] ?? []).prefix(AgentPaneToolCard.maximumShown))
            guard asks != shown[tab] ?? [] else { continue }
            set(asks, tab: tab, services: services)
        }
    }

    private func set(_ asks: [Shown], tab: String, services: AppServices) {
        let shownNow = services.cloud.toolCards.set(asks.map(Self.card), owner: Self.owner, tab: tab) { [weak self, weak services] card, action in
            guard let self, let services, let action = Action(rawValue: action) else { return }
            self.answer(card, action, tab: tab, services: services)
        }
        // A chat with no page to show them is tried again next round.
        shown[tab] = asks.isEmpty || !shownNow ? nil : asks
    }

    /// The person's click on `action` of card `card`: the card goes, and the answer names exactly what it showed.
    private func answer(_ card: String, _ action: Action, tab: String, services: AppServices) {
        guard let asks = shown[tab], let ask = asks.first(where: { $0.card == card }), let how = Self.how(action, ask.ask),
              let binary = services.cloud.move.cli else { return }
        let id = ask.ask.requestID
        answering.insert(id)
        set(asks.filter { $0.card != card }, tab: tab, services: services)
        let logger = services.cloud.logger
        Task { @MainActor [weak self] in
            let answer: CloudAccessCLI.Answer
            do {
                answer = try await CloudAccessCLI(binary: binary).answer(socket: ask.socket, machine: ask.machineID, session: ask.session,
                                                                         request: id, remoteRoot: ask.remoteRoot, how: how)
            } catch {
                answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
            }
            // `request_changed`: this Mac sees the path differently now; the next round shows it again as it is.
            if !answer.ok { logger.error("cloud access answer: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .public)") }
            guard let self else { return }
            answering.remove(id)
            answered[id] = triages
        }
    }

    /// The answer `action` gives `ask`, nil when its card doesn't offer it.
    private static func how(_ action: Action, _ ask: CloudAccessCLI.FileAsk) -> CloudAccessCLI.How? {
        switch action {
        case .allow:
            guard allowsOnce(ask), let target = ask.target else { return nil }
            return .allow(path: ask.path, target: target)
        case .always:
            guard let target = ask.target, let folder = ask.alwaysFolder else { return nil }
            return .always(path: ask.path, target: target, folder: folder)
        case .deny:
            return .deny
        }
    }

    private static func allowsOnce(_ ask: CloudAccessCLI.FileAsk) -> Bool { ask.shareable && ask.folder == false && ask.target != nil }

    private static func card(_ shown: Shown) -> AgentPaneToolCard {
        let ask = shown.ask
        let shareable = ask.shareable && ask.target != nil
        var text = shareable ? CloudAccessStrings.ask(shown.machineName, ask.path) : CloudAccessStrings.unshareable(shown.machineName, ask.path)
        if shareable, let target = ask.target, target != ask.path { text += " " + CloudAccessStrings.leadsTo(target) }
        if let reason = ask.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            text += " " + CloudAccessStrings.reason(reason.count > 200 ? String(reason.prefix(200)) + "…" : reason)
        }
        var actions: [AgentPaneToolCard.Action] = []
        if shareable, allowsOnce(ask) { actions.append(.init(id: Action.allow.rawValue, title: CloudAccessStrings.allowOnce)) }
        if shareable, let folder = ask.alwaysFolder {
            actions.append(.init(id: Action.always.rawValue, title: CloudAccessStrings.always(URL(fileURLWithPath: folder).lastPathComponent),
                                 hint: CloudAccessStrings.alwaysHint(folder)))
        }
        actions.append(.init(id: Action.deny.rawValue, title: CloudAccessStrings.deny))
        return AgentPaneToolCard(id: shown.card, state: .ask, text: text, actions: actions)
    }

    /// The tab of moved chat `chat` on `machine`: the one bound to its session through its `registry:` host.
    private static func tab(of chat: CloudMovedChats.Entry, on machine: CloudMachineSession, services: AppServices) -> String? {
        let tabs = services.agentTabs
        return machine.daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { tab in
            guard let record = tab.agentSession, record.host == chat.host else { return false }
            return (record.session ?? tabs.sessions[tabs.resolve(tab.id)]) == chat.session
        }?.id
    }

    /// The work root (``CloudMoveSetup/workRoots``) the chat's synced folder is under.
    private static func remoteRoot(_ folder: String, roots: [String]) -> String? {
        roots.first { folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
