import Foundation
import Observation

/// State behind the machine menu's Network sheet: load the stored policy,
/// edit it with ``CloudNetworkPolicyEditorModel``, save it, and show whether
/// the provider applied it. Backend calls are injected so tests drive it
/// without a server; the app binds them to ``VMClient``.
@MainActor
@Observable
final class CloudNetworkPolicySheetModel {
    typealias Load = @MainActor (String) async throws -> CloudNetworkPolicyStatus
    typealias Save = @MainActor (String, CloudNetworkPolicy) async throws -> CloudNetworkPolicyStatus

    enum Phase: Equatable {
        case loading
        case ready
        case loadFailed(String)
    }

    enum Outcome: Equatable {
        case saved
        case cancelled
    }

    let machineID: String
    let machineLabel: String
    let editor = CloudNetworkPolicyEditorModel()
    private(set) var phase: Phase = .loading
    private(set) var applied: CloudNetworkApplied?
    private(set) var isSaving = false
    private(set) var saveError: String?
    private(set) var outcome: Outcome?
    /// The policy the server last confirmed; Save is enabled only when the draft differs.
    private(set) var storedPolicy: CloudNetworkPolicy?

    var onFinished: (@MainActor (Outcome) -> Void)?

    private let loadStatus: Load
    private let saveStatus: Save

    init(machineID: String, machineLabel: String? = nil, load: @escaping Load, save: @escaping Save) {
        self.machineID = machineID
        self.machineLabel = machineLabel.flatMap { $0.isEmpty ? nil : $0 } ?? machineID
        self.loadStatus = load
        self.saveStatus = save
    }

    var hasChanges: Bool {
        guard let storedPolicy else { return false }
        return editor.policy != storedPolicy
    }

    var canSave: Bool { phase == .ready && hasChanges && !isSaving }

    func load() async {
        phase = .loading
        do {
            let status = try await loadStatus(machineID)
            accept(status)
            phase = .ready
        } catch {
            phase = .loadFailed(Self.message(for: error))
        }
    }

    /// Saves the draft. A policy the provider applied at once closes the
    /// sheet; a pending or failed one keeps it open so the state is visible.
    func save() async {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let status = try await saveStatus(machineID, editor.policy)
            accept(status)
            if (status.applied?.state ?? .applied) == .applied {
                finish(.saved)
            }
        } catch {
            saveError = Self.message(for: error)
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    /// Closes after a save whose apply is still pending; the change is stored.
    func done() {
        finish(.saved)
    }

    private func accept(_ status: CloudNetworkPolicyStatus) {
        storedPolicy = status.policy
        applied = status.applied
        editor.load(policy: status.policy, catalog: status.catalog)
    }

    private func finish(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        onFinished?(outcome)
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
