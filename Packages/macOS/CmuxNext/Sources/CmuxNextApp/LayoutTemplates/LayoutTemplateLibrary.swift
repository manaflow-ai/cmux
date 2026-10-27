import CmuxNextWakeups
import Foundation
import Observation

/// The layout templates the app shows (New Workspace from Template's list, Manage Layout
/// Templates), mirrored from `LayoutTemplateRepository`: every change goes through the
/// repository and the list is replaced with what it returns. Owned by `AppServices`.
///
/// R-hop: the repository's reads and writes run on its actor from nonisolated tasks; each list
/// replacement is one classed task on the main thread (the launch read `visible`, a change `userBlocking`:
/// the rest of the save, rename or delete that started it).
@MainActor
@Observable
final class LayoutTemplateLibrary {
    /// Every template, oldest save first (empty until ``load()`` ran).
    private(set) var templates: [LayoutTemplate] = []
    @ObservationIgnored private let repository: LayoutTemplateRepository
    @ObservationIgnored private let mainWork: MainWorkScheduler
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The newest change; each change waits for the one before it.
    @ObservationIgnored private var lastChange: Task<Void, Never>?

    /// - Parameters:
    ///   - repository: Where the templates are kept.
    ///   - mainWork: The app's main-thread scheduler; each list replacement is one task on it.
    init(repository: LayoutTemplateRepository, mainWork: MainWorkScheduler) {
        self.repository = repository
        self.mainWork = mainWork
    }

    /// Reads the saved templates once (later calls wait for that read).
    func load() async {
        await beginLoad().value
    }

    /// The template named `name`, ignoring case and surrounding whitespace.
    func template(named name: String) -> LayoutTemplate? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return templates.first { LayoutTemplateRepository.same($0.name, name) }
    }

    /// Saves `blueprint` as template `name` (replacing one of that name).
    func save(name: String, blueprint: WorkspaceBlueprint) async throws {
        try await enqueue { repository in try await repository.put(name: name, blueprint: blueprint) }.value
    }

    /// Renames template `id` to `name`; throws `LayoutTemplateRepository.Failure.nameTaken` when
    /// another template has that name.
    func rename(_ id: String, to name: String) async throws {
        try await enqueue { repository in try await repository.rename(id: id, to: name) }.value
    }

    /// Deletes template `id`.
    func delete(_ id: String) async throws {
        try await enqueue { repository in try await repository.delete(id: id) }.value
    }

    /// Deletes template `id` without waiting (a palette row's Delete); ``settled()`` waits for it.
    func deleteLater(_ id: String) {
        enqueue { repository in try await repository.delete(id: id) }
    }

    /// Waits for every change started so far (a list that must show their result).
    func settled() async {
        await load()
        await lastChange?.value
    }

    /// Starts `body` after the load and the changes before it (in this turn, so ``settled()``
    /// sees it at once); the list it returns replaces ``templates``, in change order.
    @discardableResult
    private func enqueue(_ body: @escaping @Sendable (LayoutTemplateRepository) async throws -> [LayoutTemplate]) -> Task<Void, any Error> {
        let previous = lastChange, repository = repository, mainWork = mainWork, loaded = beginLoad()
        // task-owner: the change chain (`lastChange`); settled() and the async callers await it
        let work = Task { @concurrent [weak self] () async throws in
            await loaded.value
            await previous?.value
            let list = try await body(repository)
            await mainWork.apply(.userBlocking, owner: "LayoutTemplateLibrary.change") { [weak self] in self?.templates = list }
        }
        lastChange = Task { @concurrent in _ = try? await work.value }
        return work
    }

    /// The one read, started now when it has not; ``load()`` awaits it. The launch starts it without waiting.
    @discardableResult
    func beginLoad() -> Task<Void, Never> {
        if let loading { return loading }
        let repository = repository, mainWork = mainWork
        // task-owner: the one read (`loading`); every later load and change awaits it
        let read = Task { @concurrent [weak self] in
            let all = await repository.all()
            await mainWork.apply(.visible, owner: "LayoutTemplateLibrary.load") { [weak self] in self?.templates = all }
        }
        loading = read
        return read
    }
}
