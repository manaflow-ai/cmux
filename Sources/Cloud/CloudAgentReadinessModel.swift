import CmuxCloud
import Foundation
import Observation

/// State behind the Cloud Secrets sheet's Agents section for one machine: the
/// readiness rows from ``CloudAgentReadinessService`` (the `vm.agent_readiness`
/// path), when they were checked, and whether the last check tested keys.
@MainActor
@Observable
final class CloudAgentReadinessModel {
    enum Phase: Equatable {
        case idle
        case checking
        case loaded
        /// The machine answered but could not run the check.
        case unavailable
        case failed(String)
    }

    let machineID: String
    /// How fixes address the machine.
    let machineAddress: String
    private(set) var phase: Phase = .idle
    private(set) var assessments: [CloudAgentReadinessAssessment] = []
    private(set) var checkedAt: Date?
    /// Whether the rows shown came from a check that asked each provider.
    private(set) var probed = false

    @ObservationIgnored private let service: CloudAgentReadinessService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(machineID: String, machineLabel: String?, service: CloudAgentReadinessService) {
        self.machineID = machineID
        self.machineAddress = machineLabel.flatMap { $0.isEmpty ? nil : $0 } ?? machineID
        self.service = service
    }

    var isChecking: Bool { phase == .checking }

    /// The first look when the section appears: no key leaves the machine.
    func checkIfNeeded() {
        guard phase == .idle else { return }
        check(probe: false)
    }

    /// Check Now: also asks each key's own provider whether it accepts the key.
    /// A newer check replaces one in flight.
    func check(probe: Bool) {
        task?.cancel()
        generation += 1
        let current = generation
        phase = .checking
        let machineID = machineID
        let service = service
        let request = CloudAgentReadinessRequest(probe: probe)
        task = Task { [weak self] in
            do {
                let result = try await service.check(machineID: machineID, request: request)
                self?.finish(result, generation: current)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(generation: current)
            }
        }
    }

    /// Waits for the check in flight, if any (tests and callers that chain on it).
    func settle() async {
        await task?.value
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .checking { phase = assessments.isEmpty ? .idle : .loaded }
    }

    private func finish(_ result: CloudAgentReadinessService.Result, generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        checkedAt = result.checkedAt
        probed = false
        guard result.report != nil else {
            assessments = []
            phase = .unavailable
            return
        }
        assessments = result.assessments(machine: machineAddress)
        probed = result.request.probe
        phase = .loaded
    }

    /// Fixed copy: an exec error can name a request, never a value, but the
    /// section has no use for its wording.
    private func fail(generation: Int) {
        guard generation == self.generation else { return }
        task = nil
        phase = .failed(String(
            localized: "cloudAgentReadiness.ui.failed",
            defaultValue: "The machine could not be checked. Make sure it is running, then check again."
        ))
    }

    // MARK: - Presentation

    /// "Checked just now" / "Checked 5 min ago".
    func checkedLabel(now: Date, locale: Locale = CloudSecretsSheetPresentation.interfaceLocale()) -> String? {
        guard let checkedAt else { return nil }
        guard let relative = CloudSecretsSheetPresentation.relativePhrase(checkedAt, now: now, locale: locale) else {
            return String(localized: "cloudAgentReadiness.ui.checkedJustNow", defaultValue: "Checked just now")
        }
        return String(format: String(localized: "cloudAgentReadiness.ui.checked", defaultValue: "Checked %@"), relative)
    }

    /// The rows that need the person: problems first, then attention.
    var issues: [CloudAgentReadinessAssessment] {
        assessments.filter { $0.status == .problem } + assessments.filter { $0.status == .attention }
    }

    /// The Cloud Secrets name a row's button adds or replaces, when adding a key
    /// is the fix: an agent with no credential, or a key its provider rejected.
    static func keyToSet(for assessment: CloudAgentReadinessAssessment) -> String? {
        let entry = assessment.entry
        guard entry.installed, assessment.status == .problem else { return nil }
        switch entry.source {
        case .none:
            return CloudAgentReadinessAssessment.suggestedKey(for: entry.agent)
        case .key:
            if case .status(let code) = entry.probe, code == 401 || code == 403 { return entry.keyName }
            return nil
        case .login, .routing, .config:
            return nil
        }
    }
}
