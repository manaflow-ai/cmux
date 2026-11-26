import CmuxFoundation
import Foundation
import Observation

/// Owns the Settings lifecycle for local tmux discovery and actions.
///
/// Refreshes run in a replaceable read lane. Start and attach run in their own
/// lane that leaving the view or refreshing never cancels, so the CLI is not
/// killed between creating a tmux session and recording or attaching it. A
/// generation fence keeps an older response from publishing.
@MainActor
@Observable
final class LocalTmuxSettingsModel {
    enum Phase: Equatable {
        case idle
        case loading
        case acting
    }

    private enum TaskKey: Hashable, Sendable {
        case request
        case action
    }

    private let hostActions: SettingsHostActions
    @ObservationIgnored private let tasks = MainActorTaskStore<TaskKey>()
    @ObservationIgnored private var requestGeneration: UInt64 = 0

    private(set) var sessions: [LocalTmuxSessionSummary] = []
    private(set) var liveSessionCount = 0
    var sessionName = ""
    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?

    var isLoading: Bool { phase == .loading }
    var actionInFlight: Bool { phase == .acting }
    /// True while a start or attach runs, even after cancel() stops publishing
    /// its result. A second action must not replace, and so kill, a live one.
    private(set) var actionRunning = false
    var canStartAction: Bool { phase == .idle && !actionRunning }

    init(hostActions: SettingsHostActions) {
        self.hostActions = hostActions
    }

    deinit {}

    /// Replaces any older request with an authoritative session refresh.
    func refresh() {
        let generation = beginRequest(phase: .loading)
        tasks.replaceOnMainActor(.request) { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await loadSnapshot(generation: generation)
                finish(generation: generation)
            } catch {
                fail(error, generation: generation, clearSessions: true)
            }
        }
    }

    /// Starts the typed session name, then refreshes.
    func startSession() {
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !actionRunning else { return }

        let generation = beginRequest(phase: .acting)
        actionRunning = true
        tasks.replaceOnMainActor(.action) { @MainActor [weak self] in
            guard let self else { return }
            defer { actionRunning = false }
            do {
                try await hostActions.startLocalTmuxSession(name: name)
                guard isCurrent(generation) else { return }
                sessionName = ""
                try await loadSnapshot(generation: generation)
                finish(generation: generation)
            } catch {
                fail(error, generation: generation, clearSessions: false)
            }
        }
    }

    /// Attaches one session, then refreshes.
    func attach(_ session: LocalTmuxSessionSummary) {
        guard !actionRunning else { return }
        let generation = beginRequest(phase: .acting)
        actionRunning = true
        tasks.replaceOnMainActor(.action) { @MainActor [weak self] in
            guard let self else { return }
            defer { actionRunning = false }
            do {
                try await hostActions.attachLocalTmuxSession(session)
                guard isCurrent(generation) else { return }
                try await loadSnapshot(generation: generation)
                finish(generation: generation)
            } catch {
                fail(error, generation: generation, clearSessions: false)
            }
        }
    }

    /// Stops publishing the current request's result and cancels a read-only
    /// refresh. A start or attach keeps running to completion.
    func cancel() {
        requestGeneration &+= 1
        tasks.cancel(.request)
        phase = .idle
    }

    private func beginRequest(phase: Phase) -> UInt64 {
        requestGeneration &+= 1
        self.phase = phase
        errorMessage = nil
        return requestGeneration
    }

    private func loadSnapshot(generation: UInt64) async throws {
        let loadedSessions = try await hostActions.localTmuxSessions()
        guard isCurrent(generation) else { return }
        sessions = loadedSessions
        liveSessionCount = loadedSessions.lazy.filter(\.isLive).count
        errorMessage = nil
    }

    private func finish(generation: UInt64) {
        guard isCurrent(generation) else { return }
        phase = .idle
    }

    private func fail(
        _ error: Error,
        generation: UInt64,
        clearSessions: Bool
    ) {
        guard isCurrent(generation) else { return }
        if clearSessions {
            sessions = []
            liveSessionCount = 0
        }
        errorMessage = error.localizedDescription
        phase = .idle
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        !Task.isCancelled && requestGeneration == generation
    }
}
