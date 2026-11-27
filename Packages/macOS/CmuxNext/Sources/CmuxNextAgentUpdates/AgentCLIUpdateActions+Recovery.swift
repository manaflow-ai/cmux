import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSettings
import Foundation

extension AgentCLIUpdateActions {
    /// Recovered metadata selects only an already admitted original owner.
    /// No outcome of this read authorizes an execution request.
    func recover() async throws {
        guard let persistence else { throw DaemonError.notConnected }
        let listed: [AgentCLIStoredIntent]
        do { listed = try await persistence.list() } catch {
            // An unread ledger shows no stale rows; nothing can start without reading it anyway.
            retained = []
            throw error
        }
        // A settled key whose delete failed earlier is deleted again, never restored.
        let unsettled = listed.filter { settled.contains($0.intent.key) }.map(\.intent.key)
        if !unsettled.isEmpty { try? await persistence.settle(unsettled) }
        retained = listed.filter { !settled.contains($0.intent.key) }
        for stored in retained {
            let input = stored.intent
            var intent = intents.values.first { $0.inputs.contains { $0.key == input.key } }
            if let intent { setFlags(resume: false, dismiss: false, key: input.key, in: intent) }
            if intent?.busy == true { continue }
            do {
                if let intent {
                    // The same owner rule as showing and blocking: the captured route, or the same
                    // machine and session after a reconnect.
                    guard owner(of: intent) != nil else { throw DaemonError.notConnected }
                } else {
                    let route = try captureRecovered(input.machine, input.session)
                    guard route.machine == input.machine, route.session == input.session, route.isCurrent() else { throw DaemonError.notConnected }
                    let restored = Intent(route: route, invocation: ActionInvocation(origin: .user))
                    restored.inputs = [input]; restored.jobs = [Self.job(input)]; restored.restored = true
                    intents[input.key] = restored; intent = restored
                }
                guard let intent, intent.route.isCurrent() else { continue }
                if let saved = stored.receipt, !intent.receipts.contains(where: { $0.path == saved.path && $0.revision == saved.revision }) {
                    try remember(saved, for: input, in: intent)
                }
                if let known = intent.receipts.first(where: { $0.cli == input.family }),
                   intent.jobs.contains(where: { $0["intent_key"]?.stringValue == input.key && $0["terminal"]?.stringValue == known.path.terminalID.rawValue }) {
                    if stored.receipt == nil { try await persistence.attach(input, known) }
                    continue
                }
                guard let resolve = intent.route.resolve else { continue }
                let result = try await resolve(input.family, input.key)
                guard intent.route.isCurrent() else { continue }
                switch result {
                case .created(let receipt):
                    if let saved = stored.receipt {
                        guard saved.path == receipt.path, saved.revision == receipt.revision else { throw DaemonError.malformedResponse("Recovered terminal changed") }
                    }
                    try remember(receipt, for: input, in: intent)
                    try await persistence.attach(input, receipt)
                case .notFound, .prepared:
                    // Nothing runs for the key: the person may resume it or let it go. A lost reply's
                    // replay would be a new execution request with no fresh gesture, so it waits for Resume.
                    intent.unsent[input.cli] = nil
                    setFlags(resume: true, dismiss: true, key: input.key, in: intent)
                case .indeterminate:
                    // The owner cannot tell; only the person can stop it blocking.
                    setFlags(resume: false, dismiss: true, key: input.key, in: intent)
                case .failed:
                    // The owner's durable result is terminal.
                    await settle(input.key, in: intent)
                case .pending:
                    // A creation still pending long after a recovery first saw it may be let go.
                    let since = pendingSince[input.key] ?? now()
                    pendingSince[input.key] = since
                    setFlags(resume: false, dismiss: now().timeIntervalSince(since) >= Self.pendingDismissAfter, key: input.key, in: intent)
                }
            } catch {
                // A withdrawn route or uncertain read retains the Rust record.
                // It cannot select a replacement owner or start another update.
            }
        }
    }

    func resume(_ key: String) async throws -> JSONValue {
        guard let persistence else { throw DaemonError.notConnected }
        try await recover()
        guard let input = retained.first(where: { $0.intent.key == key })?.intent,
              let intent = intents.values.first(where: { $0.inputs.contains { $0.key == key } }),
              !intent.busy, intent.route.isCurrent() else { throw DaemonError.notConnected }
        if intent.jobs.contains(where: { $0["intent_key"]?.stringValue == key && $0["terminal"] != nil }) { return state }
        guard let resolve = intent.route.resolve else { throw DaemonError.notConnected }
        intent.busy = true
        setFlags(resume: false, dismiss: false, key: key, in: intent)
        defer { intent.busy = false }
        let result = try await resolve(input.family, input.key)
        guard intent.route.isCurrent() else { throw DaemonError.notConnected }
        switch result {
        case .created(let receipt):
            try remember(receipt, for: input, in: intent)
            try await persistence.attach(input, receipt)
        case .notFound, .prepared:
            try await persistence.record([input])
            guard intent.route.isCurrent() else { throw DaemonError.notConnected }
            let receipt: AgentCLIJobReceipt
            do {
                receipt = try await intent.route.start(input.family, input.key)
            } catch {
                // A definitive refusal settles the intent; Resume would only be refused again.
                // A lost reply is replayed by refresh under this gesture, like a first start's.
                if Self.refusedBeforeCreation(error) { await settle(key, in: intent) } else { intent.unsent[input.cli] = key }
                throw error
            }
            try await accept(receipt, for: input, in: intent)
            try await persistence.attach(input, receipt)
        case .failed:
            await settle(key, in: intent)
            throw ActionFailure(message: unsupported())
        case .pending, .indeterminate:
            throw ActionFailure(message: unsupported())
        }
        return state
    }

    /// A person dismisses an intent that nothing runs for, or that the owner cannot resolve.
    /// Dismissing stops it blocking another update; it never stops a process.
    func dismiss(_ key: String) async throws {
        try await recover()
        if unreachableRows().contains(where: { $0.key == key }) {
            // No route reaches the row's owner, so only this local ledger delete can stop it blocking.
            let holder = intents.values.first { $0.inputs.contains { $0.key == key } }
            guard holder?.busy != true else { throw ActionFailure(message: unsupported()) }
            await settle(key, in: holder)
            return
        }
        guard let intent = intents.values.first(where: { $0.inputs.contains { $0.key == key } }), !intent.busy,
              intent.jobs.contains(where: { $0["intent_key"]?.stringValue == key && $0["can_dismiss"] == true }) else {
            throw ActionFailure(message: unsupported())
        }
        await settle(key, in: intent)
    }

    /// A terminal outcome: the ledger forgets the key, so it stops blocking and resuming.
    /// With `intent`, nothing ran and its job line goes too; an exit keeps its outcome shown.
    func settle(_ key: String, in intent: Intent?) async {
        settled.insert(key); pendingSince[key] = nil
        retained.removeAll { $0.intent.key == key }
        if let intent {
            intent.jobs.removeAll { $0["intent_key"]?.stringValue == key }
            intent.inputs.removeAll { $0.key == key }
            // A settled key is never replayed.
            intent.unsent = intent.unsent.filter { $0.value != key }
        }
        // A failed delete keeps the key in `settled`; the next recovery deletes it again.
        try? await persistence?.settle([key])
    }

    /// Retained rows that no intent with a current owner shows: another or a dead session, a
    /// withdrawn route, or a foreign machine. Each still blocks its CLI on its machine (`start`)
    /// until a person dismisses it or the ledger's seven-day read bound drops it.
    func unreachableRows() -> [AgentCLIUpdateIntent] {
        let shown = Set(intents.values.filter { owner(of: $0) != nil }.flatMap { intent in
            intent.jobs.compactMap { $0["intent_key"]?.stringValue }
        })
        return retained.map(\.intent).filter { !settled.contains($0.key) && !shown.contains($0.key) }
    }

    /// An unreachable row: nothing here can observe or resume it, so its outcome is unknown.
    static func unreachableJob(_ input: AgentCLIUpdateIntent) -> JSONValue {
        guard var row = Self.job(input).objectValue else { return Self.job(input) }
        row["can_dismiss"] = true
        return .object(row)
    }

    static func job(_ input: AgentCLIUpdateIntent) -> JSONValue {
        ["machine": .string(input.machine.rawValue), "session": .string(input.session.rawValue),
         "cli": .string(input.cli), "intent_key": .string(input.key), "state": "unknown", "can_resume": false,
         "can_dismiss": false, "profiles": .array(input.profiles.map(JSONValue.string))]
    }

    /// One recorded family's start on the intent's captured route.
    func send(_ input: AgentCLIUpdateIntent, intent: Intent, route: Route, failures: inout [String]) async throws {
        guard let persistence else { throw DaemonError.notConnected }
        let receipt: AgentCLIJobReceipt
        do {
            receipt = try await route.start(input.family, input.key)
        } catch {
            // A refusal created nothing: the intent settles instead of staying resumable. Neither did
            // busy here: the owner answers it (inventory reservation, execution lock) before it looks
            // up the key, and a first start always sends a fresh key. Any other code can follow a
            // durable creation (a launch activation failing after the commit), and a lost reply may
            // have created the terminal: the row stays, recovery's resolve reads the owner's journal
            // (a failed creation settles), and refresh sends the same key again.
            if Self.refusedBeforeCreation(error) || Self.busy(error) { await settle(input.key, in: intent) } else { intent.unsent[input.cli] = input.key }
            failures.append("\(input.cli): \(Self.text(error))")
            guard route.isCurrent() else { throw error }
            return
        }
        try await accept(receipt, for: input, in: intent)
        do { try await persistence.attach(input, receipt) } catch {
            // The update started and stays tracked; its recorded row lets recovery resolve it.
            failures.append("\(input.cli): \(Self.text(error))")
        }
        guard route.isCurrent() else { throw DaemonError.notConnected }
    }

    /// A start's receipt for this intent. Another owner's terminal is not this update's and
    /// this route cannot observe it: the intent settles, leaving no job or ledger row that blocks.
    func accept(_ receipt: AgentCLIJobReceipt, for input: AgentCLIUpdateIntent, in intent: Intent) async throws {
        guard receipt.machine == input.machine, receipt.session == input.session, receipt.cli == input.family else {
            await settle(input.key, in: intent)
            throw DaemonError.malformedResponse("Agent update receipt owner mismatch")
        }
        try remember(receipt, for: input, in: intent)
    }

    /// Sends each start whose reply was lost again with its own key, on the intent's owner (a
    /// re-capture after a reconnect included), under the gesture that sent it first; the owner
    /// replays an accepted key. A receipt attaches to the ledger row, a refusal settles it, and
    /// busy (the key's original request may still run) or another lost reply keeps both.
    /// A replay holds its intent busy, so a dismiss cannot delete the row its receipt attaches to.
    func replayUnsent() async {
        for intent in intents.values where !intent.busy && !intent.unsent.isEmpty {
            intent.busy = true
            defer { intent.busy = false }
            for (family, key) in intent.unsent.sorted(by: { $0.key < $1.key }) {
                guard let route = owner(of: intent) else { break }
                // Recovery may have attached its receipt already, or the key settled.
                guard let input = intent.inputs.first(where: { $0.key == key }),
                      intent.jobs.contains(where: { $0["intent_key"]?.stringValue == key && $0["terminal"] == nil }) else {
                    intent.unsent[family] = nil
                    continue
                }
                do {
                    let receipt = try await route.start(input.family, key)
                    guard route.isCurrent(), intent.unsent[family] == key else { continue }
                    intent.unsent[family] = nil
                    try await accept(receipt, for: input, in: intent)
                    // A failed attach keeps the row; the next recovery attaches the known receipt.
                    try? await persistence?.attach(input, receipt)
                } catch where Self.refusedBeforeCreation(error) {
                    guard intent.unsent[family] == key else { continue }
                    intent.unsent[family] = nil
                    await settle(key, in: intent)
                } catch {
                    // Lost again or busy: the job and row stay, and the next refresh replays the key.
                }
            }
        }
    }

    func remember(_ receipt: AgentCLIJobReceipt, for input: AgentCLIUpdateIntent, in intent: Intent) throws {
        guard receipt.machine == input.machine, receipt.session == input.session, receipt.cli == input.family,
              let index = intent.jobs.firstIndex(where: { $0["intent_key"]?.stringValue == input.key }),
              var job = intent.jobs[index].objectValue else { throw DaemonError.malformedResponse("Receipt does not match the retained intent") }
        let added = !intent.receipts.contains(where: { $0.path.terminalID == receipt.path.terminalID })
        if added { intent.receipts.append(receipt) }
        job["terminal"] = .string(receipt.path.terminalID.rawValue); job["state"] = "created"
        job["can_resume"] = false; job["can_dismiss"] = false
        intent.jobs[index] = .object(job)
        if added {
            // A batch may gain a receipt while a previous bounded read is in flight.
            // Restart observation only; cancellation never ends the owner's job.
            intent.following?.cancel(); intent.following = nil
            follow(intent)
        }
    }

    private func setFlags(resume: Bool, dismiss: Bool, key: String, in intent: Intent) {
        guard let index = intent.jobs.firstIndex(where: { $0["intent_key"]?.stringValue == key }), var job = intent.jobs[index].objectValue else { return }
        job["can_resume"] = .bool(resume); job["can_dismiss"] = .bool(dismiss); intent.jobs[index] = .object(job)
    }
}
