#if DEBUG
import AppKit
import Foundation

/// The `debug.cloud_first_run.*` socket verbs' view of the first-run tour, so
/// evaluators can drive it and time it without Accessibility grants:
///
/// - `debug.cloud_first_run.show` presents it (the Get started card's path);
/// - `debug.cloud_first_run.state` reads steps, phases and timings;
/// - `debug.cloud_first_run.interact {action, value?}` with `set_agent`,
///   `set_repo`, `use_sample`, `set_prompt`, `set_key`, `go`, `recover`, `hide`,
///   `cancel` (the Cancel button).
///
/// State carries names, phases and durations. A typed key is reported only as
/// `key_typed: true`; its value is never read back.
@MainActor
enum CloudFirstRunDebugProbe {
    enum Action: String, CaseIterable {
        case setAgent = "set_agent"
        case setRepo = "set_repo"
        case useSample = "use_sample"
        case setPrompt = "set_prompt"
        case setKey = "set_key"
        case go
        case recover
        case hide
        /// The Cancel button: cancels before Go (cleaning up the tour's machine), hides after.
        case cancel
    }

    static func state(presenter: CloudFirstRunPresenter) -> [String: Any] {
        var result: [String: Any] = ["open": presenter.isPresented]
        if let line = presenter.lastTimingLine { result["last_timing_line"] = line }
        guard let model = presenter.currentModel else {
            result["active"] = false
            return result
        }
        result["active"] = true
        result["agent"] = model.agent.rawValue
        result["repo"] = model.repoText
        result["repo_argument"] = model.repoReference?.cloneArgument ?? NSNull()
        result["prompt_length"] = model.trimmedPrompt.count
        result["key_source"] = keySourceName(model.keySource)
        result["key_typed"] = !model.typedKey.isEmpty
        result["machine"] = machineState(model.machine)
        result["run"] = runName(model.run)
        result["clone_phases_finished"] = model.progress.finishedPhases
        result["can_go"] = model.canGo
        result["machine_origin"] = originName(model.origin)
        if case .provisioned(let machineID) = model.origin {
            result["provisioned_machine"] = machineID
        } else {
            result["provisioned_machine"] = NSNull()
        }
        result["cancel_deletes_machine"] = model.cancelDeletesMachine
        result["cleanup"] = model.lastCleanup.rawValue
        var steps: [String: String] = [:]
        for step in CloudFirstRunModel.Step.allCases {
            steps[step.rawValue] = stepName(model.state(of: step))
        }
        result["steps"] = steps
        if let failure = model.currentFailure {
            result["failure"] = ["reason": failure.reason, "recovery": failure.recovery.rawValue]
        }
        var marks: [String: Double] = [:]
        for mark in CloudFirstRunTimeline.Mark.allCases {
            if let seconds = model.timeline.seconds(mark) { marks[mark.rawValue] = (seconds * 10).rounded() / 10 }
        }
        result["timeline"] = marks
        result["elapsed"] = (model.timeline.elapsed(now: Date()) * 10).rounded() / 10
        if case .started(let clone) = model.run {
            result["agent_terminal_id"] = clone.agentTerminalID ?? NSNull()
            result["clone_timings"] = clone.timings
        }
        return result
    }

    enum Outcome {
        case applied
        case ignored(String)
        case invalid(String)
    }

    static func perform(_ raw: String?, value: String?, presenter: CloudFirstRunPresenter) -> Outcome {
        guard let raw, let action = Action(rawValue: raw) else {
            return .invalid("action must be one of \(Action.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if action == .hide {
            presenter.hide()
            return .applied
        }
        if action == .cancel {
            presenter.close()
            return .applied
        }
        guard let model = presenter.currentModel else {
            return .ignored("the tour is not active; call debug.cloud_first_run.show first")
        }
        switch action {
        case .setAgent:
            guard let value, let agent = CloudFirstRunAgent(rawValue: value) else {
                return .invalid("value must be one of \(CloudFirstRunAgent.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            model.agent = agent
        case .setRepo:
            model.repoText = value ?? ""
        case .useSample:
            model.useSampleRepo()
        case .setPrompt:
            model.prompt = value ?? ""
        case .setKey:
            model.typedKey = value ?? ""
        case .go:
            guard model.canGo else { return .ignored("Start Agent is disabled; read debug.cloud_first_run.state") }
            model.go()
        case .recover:
            guard let failure = model.currentFailure else { return .ignored("nothing has failed") }
            if !model.perform(failure.recovery), failure.recovery == .addGitHubToken {
                let window = NSApp.keyWindow ?? NSApp.mainWindow
                presenter.leave(for: .secrets, preferredWindow: window)
                CloudSecretsSheetPresenter.shared.present(preferredWindow: window)
            }
        case .hide, .cancel:
            break
        }
        return .applied
    }

    private static func originName(_ origin: CloudFirstRunModel.MachineOrigin) -> String {
        switch origin {
        case .none: return "none"
        case .reused: return "reused"
        case .provisioning: return "provisioning"
        case .provisioned: return "provisioned"
        }
    }

    private static func keySourceName(_ source: CloudFirstRunKeySource) -> String {
        switch source {
        case .vault(let name): return "vault:\(name)"
        case .teamRouter: return "team_router"
        case .typed: return "typed"
        case .missing: return "missing"
        }
    }

    private static func machineState(_ state: CloudFirstRunModel.MachineState) -> [String: Any] {
        switch state {
        case .looking: return ["state": "looking"]
        case .starting: return ["state": "starting"]
        case .ready(let machine): return ["state": "ready", "id": machine.id, "name": machine.name]
        case .failed(let failure): return ["state": "failed", "recovery": failure.recovery.rawValue]
        }
    }

    private static func runName(_ run: CloudFirstRunModel.RunState) -> String {
        switch run {
        case .editing: return "editing"
        case .savingKey: return "saving_key"
        case .waitingForMachine: return "waiting_for_machine"
        case .cloning: return "cloning"
        case .started: return "started"
        case .failed: return "failed"
        }
    }

    private static func stepName(_ state: CloudFirstRunModel.StepState) -> String {
        switch state {
        case .waiting: return "waiting"
        case .working: return "working"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}
extension TerminalController {
    /// `debug.cloud_first_run.show` / `.state` / `.interact`, dispatched from
    /// `v2DebugCloudUI` on the main-actor lane.
    func v2DebugCloudFirstRun(id: Any?, method: String, params: [String: Any]) -> String {
        let presenter = CloudFirstRunPresenter.shared
        switch method {
        case "debug.cloud_first_run.show":
            let preferred = NSApp.keyWindow ?? NSApp.mainWindow
            // The same call the Get started card and the welcome make.
            presenter.present(preferredWindow: preferred)
            var result = CloudFirstRunDebugProbe.state(presenter: presenter)
            if let preferred,
               let tabManager = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: preferred),
               let windowID = AppDelegate.shared?.windowId(for: tabManager) {
                result["window_id"] = windowID.uuidString
                result["window_ref"] = v2Ref(kind: .window, uuid: windowID)
            }
            return v2Ok(id: id, result: result)
        case "debug.cloud_first_run.state":
            return v2Ok(id: id, result: CloudFirstRunDebugProbe.state(presenter: presenter))
        default:
            let action = params["action"] as? String
            switch CloudFirstRunDebugProbe.perform(action, value: params["value"] as? String, presenter: presenter) {
            case .applied:
                return v2Ok(id: id, result: ["action": action ?? "", "applied": true])
            case .ignored(let reason):
                return v2Ok(id: id, result: ["action": action ?? "", "applied": false, "reason": reason])
            case .invalid(let message):
                return v2Error(id: id, code: "invalid_params", message: message)
            }
        }
    }
}
#endif
