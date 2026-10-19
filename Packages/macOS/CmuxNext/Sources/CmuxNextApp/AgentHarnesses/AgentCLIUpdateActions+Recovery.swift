import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

extension AgentCLIUpdateActions {
    /// Recovered metadata selects only an already admitted original owner.
    /// No outcome of this read authorizes an execution request.
    func recover() async throws {
        guard let persistence else { throw DaemonError.notConnected }
        retained = try await persistence.list()
        for stored in retained {
            let input = stored.intent
            var intent = intents.values.first { $0.inputs.contains { $0.key == input.key } }
            if let intent { setResume(false, key: input.key, in: intent) }
            if intent?.busy == true { continue }
            do {
                if intent == nil || intent?.route.isCurrent() != true {
                    let route = try captureRecovered(input.machine, input.session)
                    guard route.machine == input.machine, route.session == input.session, route.isCurrent() else { throw DaemonError.notConnected }
                    if let intent { intent.route = route }
                    else {
                        let restored = Intent(route: route, profile: nil, target: nil)
                        restored.inputs = [input]; restored.jobs = [Self.job(input)]; restored.restored = true
                        intents[input.key] = restored; intent = restored
                    }
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
                    setResume(true, key: input.key, in: intent)
                case .pending, .indeterminate, .failed:
                    setResume(false, key: input.key, in: intent)
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
        setResume(false, key: key, in: intent)
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
            let receipt = try await intent.route.start(input.family, input.key)
            try remember(receipt, for: input, in: intent)
            try await persistence.attach(input, receipt)
        case .pending, .indeterminate, .failed:
            throw ActionFailure(message: AgentHarnessStrings.unsupported)
        }
        return state
    }

    static func job(_ input: AgentCLIUpdateIntent) -> JSONValue {
        ["machine": .string(input.machine.rawValue), "session": .string(input.session.rawValue),
         "cli": .string(input.cli), "intent_key": .string(input.key), "state": "unknown", "can_resume": false,
         "profiles": .array(input.profiles.map(JSONValue.string))]
    }

    func remember(_ receipt: AgentCLIJobReceipt, for input: AgentCLIUpdateIntent, in intent: Intent) throws {
        guard receipt.machine == input.machine, receipt.session == input.session, receipt.cli == input.family,
              let index = intent.jobs.firstIndex(where: { $0["intent_key"]?.stringValue == input.key }),
              var job = intent.jobs[index].objectValue else { throw DaemonError.malformedResponse("Receipt does not match the retained intent") }
        if !intent.receipts.contains(where: { $0.path.terminalID == receipt.path.terminalID }) { intent.receipts.append(receipt) }
        job["terminal"] = .string(receipt.path.terminalID.rawValue); job["state"] = "created"; job["can_resume"] = false
        intent.jobs[index] = .object(job)
    }

    private func setResume(_ allowed: Bool, key: String, in intent: Intent) {
        guard let index = intent.jobs.firstIndex(where: { $0["intent_key"]?.stringValue == key }), var job = intent.jobs[index].objectValue else { return }
        job["can_resume"] = .bool(allowed); intent.jobs[index] = .object(job)
    }
}
