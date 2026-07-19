public import Foundation
public import Observation

/// Orchestrates one work order: catalog loading, draft state, validation,
/// and the launch state machine the stamp UI renders.
///
/// Field validation is deliberately lazy — the Dispatch button stays tappable
/// and a failed attempt marks the first offending field instead of leaving the
/// user staring at a silently disabled button.
@MainActor
@Observable
public final class DispatchComposerModel {
    public enum CatalogState: Equatable {
        case loading
        case ready(DispatchCatalog)
        case failed
    }

    public enum LaunchState: Equatable {
        case idle
        case launching
        case rejected(DispatchLaunchFailure)
        case dispatched
    }

    /// The field a failed validation should visually nudge.
    public enum ValidationField: Equatable {
        case brief
        case agent
    }

    public private(set) var catalogState: CatalogState = .loading
    public private(set) var launchState: LaunchState = .idle
    public private(set) var validationNudge: ValidationField?
    /// Bumped on every repeated nudge so an already-marked field shakes again.
    public private(set) var validationNudgeGeneration = 0

    public var brief: String {
        didSet {
            guard brief != oldValue else { return }
            clearTransientFeedback()
            persistDraft()
        }
    }

    public private(set) var directoryPath: String?
    public private(set) var agentID: String?

    /// Serial stamped on this work order (increments only on launch).
    public private(set) var serial: Int

    public let service: any DispatchComposerServicing
    private let localStore: DispatchLocalStore
    private var catalogTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?

    public init(service: any DispatchComposerServicing, localStore: DispatchLocalStore = DispatchLocalStore()) {
        self.service = service
        self.localStore = localStore
        let draft = localStore.draft(macID: service.dispatchMacKey)
        brief = draft?.brief ?? ""
        directoryPath = draft?.directoryPath
        agentID = draft?.agentID
        serial = localStore.nextSerial(macID: service.dispatchMacKey)
    }

    // MARK: - Catalog

    public var catalog: DispatchCatalog? {
        if case let .ready(catalog) = catalogState { return catalog }
        return nil
    }

    public var agents: [DispatchAgent] { catalog?.agents ?? [] }
    public var recentDirectories: [DispatchDirectory] { catalog?.recentDirectories ?? [] }
    public var homePath: String? { catalog?.home }
    public var promptByteBudget: Int { catalog?.promptByteBudget ?? 900 }

    public func loadCatalogIfNeeded() {
        guard catalogTask == nil, catalog == nil else { return }
        catalogState = .loading
        catalogTask = Task { [weak self] in
            guard let self else { return }
            defer { self.catalogTask = nil }
            do {
                let catalog = try await self.service.dispatchCatalog()
                self.catalogState = .ready(catalog)
                self.applyCatalogDefaults(catalog)
            } catch {
                guard !Task.isCancelled else { return }
                self.catalogState = .failed
            }
        }
    }

    public func retryCatalog() {
        catalogTask?.cancel()
        catalogTask = nil
        catalogState = .loading
        loadCatalogIfNeeded()
    }

    private func applyCatalogDefaults(_ catalog: DispatchCatalog) {
        if directoryPath == nil {
            directoryPath = catalog.recentDirectories.first?.path ?? catalog.home
            persistDraft()
        }
        let installedIDs = catalog.agents.filter(\.installed).map(\.id)
        if agentID == nil || !catalog.agents.contains(where: { $0.id == agentID && $0.installed }) {
            agentID = installedIDs.first
            persistDraft()
        }
    }

    // MARK: - Draft fields

    public func selectDirectory(_ path: String) {
        directoryPath = path
        clearTransientFeedback()
        persistDraft()
    }

    public func selectAgent(_ id: String) {
        guard agents.first(where: { $0.id == id })?.installed == true else { return }
        agentID = id
        clearTransientFeedback()
        persistDraft()
    }

    private func persistDraft() {
        localStore.saveDraft(
            DispatchDraft(brief: brief, directoryPath: directoryPath, agentID: agentID),
            macID: service.dispatchMacKey
        )
    }

    /// Shorten a path for display by abbreviating the Mac's home directory.
    public func displayPath(_ path: String) -> String {
        guard let home = homePath, !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Budget

    public var briefByteCount: Int { brief.utf8.count }
    public var isOverBudget: Bool { briefByteCount > promptByteBudget }
    /// The counter stays hidden until the brief approaches the wire budget.
    public var showsBudgetCounter: Bool { briefByteCount * 4 >= promptByteBudget * 3 }

    // MARK: - Launch

    public var selectedAgent: DispatchAgent? {
        agents.first(where: { $0.id == agentID })
    }

    public var trimmedBrief: String {
        brief.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canAttemptDispatch: Bool {
        if case .launching = launchState { return false }
        if case .dispatched = launchState { return false }
        return true
    }

    /// Validate, then launch. Invalid input nudges the offending field instead
    /// of failing silently or pre-disabling the button.
    public func attemptDispatch() {
        guard canAttemptDispatch else { return }
        guard !trimmedBrief.isEmpty, !isOverBudget else {
            nudge(.brief)
            return
        }
        guard let agent = selectedAgent, agent.installed else {
            nudge(.agent)
            return
        }
        guard let directoryPath else {
            // No directory can only happen before the catalog resolved a default.
            nudge(.brief)
            return
        }
        let prompt = trimmedBrief
        launchState = .launching
        launchTask = Task { [weak self] in
            guard let self else { return }
            defer { self.launchTask = nil }
            let result = await self.service.dispatchLaunch(
                directory: directoryPath,
                agentID: agent.id,
                prompt: prompt
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                self.localStore.recordCompletedDispatch(macID: self.service.dispatchMacKey)
                self.localStore.clearDraft(macID: self.service.dispatchMacKey)
                self.launchState = .dispatched
            case let .failure(failure):
                self.launchState = .rejected(failure)
            }
        }
    }

    private func nudge(_ field: ValidationField) {
        validationNudge = field
        validationNudgeGeneration &+= 1
    }

    private func clearTransientFeedback() {
        validationNudge = nil
        if case .rejected = launchState {
            launchState = .idle
        }
    }

    public func cancelInFlightWork() {
        catalogTask?.cancel()
        launchTask?.cancel()
    }
}
