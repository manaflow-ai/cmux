import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// A moved chat's file and secret requests for this Mac (cmuxterm-hq#1874 slice 6): while chats a move put on
/// a connected Cloud machine (``CloudMovedChats``) exist, the app runs `cmux link access triage`
/// for each machine's chats every ``CloudMoveSetup/accessPoll`` (one run at a time), which answers
/// what needs no person, and shows each ask left as a card in that chat's tab on the machine
/// (``AgentToolCards``, never a sheet; ``CloudAccessCard``): Allow once, Always for its folder,
/// Deny; for a secret, a password field, Share once and Deny. A typed secret goes only to that
/// request's `answer`, on stdin, and is never logged or kept. Only the person's click (a real gesture in the pane, ``AgentPaneToolCard``) answers, with
/// exactly what the card showed, and only while the chat is still on the machine; nothing is
/// answered from the ask's own `exists` or `shareable`. Each chat's granted folders are copied
/// again every ``CloudMoveSetup/accessSync``, and Bring Back Local ends its grants
/// (``CloudAccessRevokes``). The polling stops with no moved chat and nothing to revoke; a move
/// starts it again.
///
/// The ask's text comes from the machine (its path and reason); the card names the machine, not
/// the chat, as the asker, since the session an ask names is the machine's claim. Only asks of the
/// sessions this Mac moved there are shown, each in that session's own tab.
@MainActor
final class CloudAccessAsks {
    /// The cards' owner in ``AgentToolCards``.
    static let owner = "cloudAccess"
    /// The longest a machine whose triage fails waits, and how long one without access requests waits.
    private static let longestBackoff: Duration = .seconds(120), unavailableBackoff: Duration = .seconds(600)

    private var loop: Task<Void, Never>?
    /// The asks the last triages listed, by chat tab, and the answers that failed.
    private var asks: [String: [CloudAccessAsk]] = [:]
    private var failures: [String: [CloudAccessAsk]] = [:]
    /// The cards set, by tab.
    private var shown: [String: [AgentPaneToolCard]] = [:]
    /// Requests whose answer is running.
    private var answering: Set<String> = []
    /// Requests answered, with the triage count when their answer ended: a triage that began by then
    /// may still list them, so it shows them no more.
    private var answered: [String: Int] = [:]
    private var triages = 0
    private var lastSync: [String: ContinuousClock.Instant] = [:]
    private var backoff: [String: (until: ContinuousClock.Instant, delay: Duration)] = [:]
    let revokes = CloudAccessRevokes()

    /// Starts polling unless it runs; it stops with no moved chat and nothing to revoke, and with this object or `services`.
    func start(services: AppServices) {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self, weak services] in
            // wakeup-allow: polls triage only while a moved chat or a revoke waits (the loop then ends); the machine pushes no access request
            while !Task.isCancelled {
                guard let pause = await self?.poll(services) else { return }
                // wakeup-allow: the poll's pause (accessPoll, or a machine's backoff), only while the loop above runs
                try? await Task.sleep(for: pause)
            }
        }
    }

    /// Bring Back Local moved chat `session` off machine `machineID`: its grants there end, now
    /// or once its machine is reachable.
    func chatBroughtBack(machineID: String, session: String, services: AppServices) {
        revokes.add(CloudAccessRevokes.Chat(machineID: machineID, session: session))
        start(services: services)
        guard let binary = services.cloud.move.cli else { return }
        let revokes = revokes
        // task-owner: one revoke round; CloudAccessRevokes keeps what is left for the poll loop
        Task { @MainActor [weak services] in
            guard let services else { return }
            await revokes.run(CloudAccessCLI(binary: binary), services: services)
        }
    }

    /// One round over the machines; how long to wait before the next, nil to stop.
    private func poll(_ services: AppServices?) async -> Duration? {
        guard let services, let binary = services.cloud.move.cli else { return stop() }
        let setup = services.cloud.move, cli = CloudAccessCLI(binary: binary)
        revokes.firstBackoff = setup.accessPoll
        for entry in services.cloud.movedChats.all() where entry.broughtBack != nil {
            revokes.add(CloudAccessRevokes.Chat(machineID: entry.machineID, session: entry.session))
        }
        await revokes.run(cli, services: services)
        // Read after the await, with no await before a stop: a move recorded meanwhile keeps the loop going.
        let chats = services.cloud.movedChats.all().filter { $0.broughtBack == nil }
        // Turned off by the organization: no request goes out, and the cards go.
        guard !chats.isEmpty, !services.machines.isFeatureDisabled(.cloud) else {
            asks = [:]
            render(services: services)
            return chats.isEmpty && revokes.isEmpty ? stop() : setup.accessPoll
        }
        triages += 1
        let triage = triages
        var next: [String: [CloudAccessAsk]] = [:]
        var liveTabs: Set<String> = []
        for (machineID, machineChats) in Dictionary(grouping: chats, by: \.machineID).sorted(by: { $0.key < $1.key }) {
            guard let machine = services.machines.session(machineID), let socket = await machine.daemon.connection?.endpoint?.socketPath else { continue }
            let sessions = Array(Set(machineChats.map(\.session))).sorted()
            for chat in machineChats { if let tab = Self.tab(of: chat, on: machine, services: services) { liveTabs.insert(tab) } }
            if let wait = backoff[machineID], ContinuousClock.now < wait.until {
                for (tab, list) in asks where list.contains(where: { $0.machineID == machineID }) { next[tab] = list }
                continue
            }
            if lastSync[machineID].map({ $0.duration(to: .now) >= setup.accessSync }) ?? true {
                lastSync[machineID] = .now
                for session in sessions { await sync(cli, socket: socket, machine: machineID, session: session, services: services) }
            }
            let answer: CloudAccessCLI.Answer
            do {
                answer = try await cli.triage(socket: socket, machine: machineID, sessions: sessions)
            } catch {
                answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
            }
            guard answer.ok else {
                services.cloud.logger.error("cloud access triage: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .public)")
                // Keep this machine's cards as they were and ask it less often; a machine with no
                // access requests (an older image) much less.
                let delay = answer.errorCode == "access_request.unavailable" ? Self.unavailableBackoff
                    : min((backoff[machineID]?.delay ?? setup.accessPoll) * 2, Self.longestBackoff)
                backoff[machineID] = (ContinuousClock.now + delay, delay)
                for (tab, list) in asks where list.contains(where: { $0.machineID == machineID }) { next[tab] = list }
                continue
            }
            backoff[machineID] = nil
            if answer.failures > 0 { services.cloud.logger.error("cloud access triage: \(answer.failures) requests failed") }
            let listed = answer.asks.map { ($0.session, CloudAccessAsk.Asked.file($0)) } + answer.secrets.map { ($0.session, CloudAccessAsk.Asked.secret($0)) }
            for (session, asked) in listed {
                guard let chat = machineChats.first(where: { $0.session == session }), let tab = Self.tab(of: chat, on: machine, services: services),
                      let root = Self.remoteRoot(chat.remoteFolder, roots: setup.workRoots) else { continue }
                next[tab, default: []].append(CloudAccessAsk(asked: asked, host: chat.host, session: chat.session, machineID: machineID,
                                                             machineName: machine.machine.title, socket: socket, remoteRoot: root))
            }
        }
        // Checked after every await: a triage that began before an answer ended may list it still;
        // one that began after shows it again.
        next = next.mapValues { list in list.filter { !answering.contains($0.requestID) && answered[$0.requestID].map { triage > $0 } ?? true } }
        for list in next.values { for ask in list { answered[ask.requestID] = nil } }
        answered = answered.filter { $0.value >= triage }
        asks = next.filter { !$0.value.isEmpty }
        // A failed answer's card goes with its chat's tab.
        failures = failures.filter { liveTabs.contains($0.key) }
        render(services: services)
        return setup.accessPoll
    }

    private func stop() -> Duration? {
        loop = nil
        return nil
    }

    private func sync(_ cli: CloudAccessCLI, socket: String, machine: String, session: String, services: AppServices) async {
        do {
            let answer = try await cli.sync(socket: socket, machine: machine, session: session)
            if !answer.ok || answer.failures > 0 {
                services.cloud.logger.error("cloud access sync: \(answer.errorCode ?? "", privacy: .public) \(answer.failures) copies failed")
            }
        } catch {
            services.cloud.logger.error("cloud access sync: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether `ask`'s chat is still on its machine: a chat brought back (or coming back) is never answered.
    private static func isLive(_ ask: CloudAccessAsk, services: AppServices) -> Bool {
        guard let entry = services.cloud.movedChats.entry(host: ask.host, session: ask.session) else { return false }
        return entry.broughtBack == nil && entry.machineID == ask.machineID
    }

    /// Sets each tab's cards (the asks of chats still on their machines, then one failed answer),
    /// at most ``AgentPaneToolCard/maximumShown`` per chat, and removes those of tabs with none.
    private func render(services: AppServices) {
        for tab in Set(shown.keys).union(asks.keys).union(failures.keys) {
            failures[tab] = failures[tab]?.filter { Self.isLive($0, services: services) }
            if failures[tab]?.isEmpty == true { failures[tab] = nil }
            // Live asks first: a failed answer's card never pushes one past the cap.
            let list = (asks[tab] ?? []).filter { Self.isLive($0, services: services) && !answering.contains($0.requestID) } + (failures[tab] ?? []).prefix(1)
            let cards = list.prefix(AgentPaneToolCard.maximumShown).map(CloudAccessCard.card)
            guard cards != shown[tab] ?? [] else { continue }
            let ok = services.cloud.toolCards.set(cards, owner: Self.owner, tab: tab) { [weak self, weak services] card, action, value in
                guard let self, let services, let action = CloudAccessCard.Action(rawValue: action) else { return }
                self.answer(card, action, value: value, tab: tab, services: services)
            }
            // A chat with no page to show them is tried again next round.
            shown[tab] = cards.isEmpty || !ok ? nil : cards
        }
    }

    /// The person's click on `action` of card `card`, with what they typed in its field (`value`, a
    /// secret): the card goes, and the answer names exactly what it showed. The value lives only in
    /// this answer's task and goes only to the CLI's stdin.
    private func answer(_ card: String, _ action: CloudAccessCard.Action, value: AgentPaneToolCard.Entered?, tab: String, services: AppServices) {
        if action == .dismiss {
            failures[tab]?.removeAll { $0.card == card }
            if failures[tab]?.isEmpty == true { failures[tab] = nil }
            return render(services: services)
        }
        guard let ask = asks[tab]?.first(where: { $0.card == card }), Self.isLive(ask, services: services),
              let how = CloudAccessCard.how(action, ask, value: value), let binary = services.cloud.move.cli else { return }
        let id = ask.requestID, chat = CloudAccessRevokes.Chat(machineID: ask.machineID, session: ask.session)
        answering.insert(id)
        revokes.answerStarted(chat)
        asks[tab]?.removeAll { $0.card == card }
        render(services: services)
        let logger = services.cloud.logger
        // task-owner: one person's answer, bounded by the CLI's timeout; `answering` tracks it
        Task { @MainActor [weak self, weak services] in
            let answer: CloudAccessCLI.Answer
            do {
                answer = try await CloudAccessCLI(binary: binary).answer(socket: ask.socket, machine: ask.machineID, session: ask.session,
                                                                         request: id, remoteRoot: ask.remoteRoot, how: how)
            } catch {
                answer = CloudAccessCLI.Answer(ok: false, error: String(describing: error))
            }
            guard let self else { return }
            answering.remove(id)
            answered[id] = triages
            // The chat came back while this ran: what it may have granted is revoked again.
            let live = services.map { Self.isLive(ask, services: $0) } ?? false
            revokes.answerEnded(chat, live: live)
            if !live, let services { chatBroughtBack(machineID: chat.machineID, session: chat.session, services: services) }
            // A changed or gone request: the next triage shows it again as it is now, if it still waits.
            guard !answer.ok, answer.errorCode != "request_changed", answer.errorCode != "request_gone" else { return }
            logger.error("cloud access answer: \(answer.errorCode ?? "", privacy: .public) \(answer.error ?? "", privacy: .public)")
            var failed = ask
            failed.failure = CloudAccessCard.failure(answer.errorCode, ask)
            failures[tab, default: []].append(failed)
            if let services { render(services: services) }
        }
    }

    /// The tab of moved chat `chat` on `machine`: the one bound to its session through its `registry:` host.
    static func tab(of chat: CloudMovedChats.Entry, on machine: CloudMachineSession, services: AppServices) -> String? {
        let tabs = services.agentTabs
        return machine.daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { tab in
            guard let record = tab.agentSession, record.host == chat.host else { return false }
            return (record.session ?? tabs.sessions[tabs.resolve(tab.id)]) == chat.session
        }?.id
    }

    /// The work root (``CloudMoveSetup/workRoots``) the chat's synced folder is under.
    static func remoteRoot(_ folder: String, roots: [String]) -> String? {
        roots.first { folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
