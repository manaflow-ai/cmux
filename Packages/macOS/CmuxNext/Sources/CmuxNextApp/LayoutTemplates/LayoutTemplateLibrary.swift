import Foundation
import Observation

/// The layout templates the app shows (New Workspace from Template's list, Manage Layout
/// Templates), mirrored from `LayoutTemplateRepository`: every change goes through the
/// repository and the list is replaced with what it returns. Owned by `AppServices`.
@MainActor
@Observable
final class LayoutTemplateLibrary {
    /// Every template, oldest save first (empty until ``load()`` ran).
    private(set) var templates: [LayoutTemplate] = []
    @ObservationIgnored private let repository: LayoutTemplateRepository
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The newest change; each change waits for the one before it.
    @ObservationIgnored private var lastChange: Task<Void, Never>?

    init(repository: LayoutTemplateRepository) {
        self.repository = repository
    }

    /// Reads the saved templates once (later calls wait for that read).
    func load() async {
        if loading == nil {
            let repository = repository
            loading = Task { [weak self] in
                let all = await repository.all()
                self?.templates = all
            }
        }
        await loading?.value
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
        let previous = lastChange, repository = repository
        // task-owner: the change chain (`lastChange`); settled() and the async callers await it
        let work = Task { [weak self] () async throws in
            await self?.load()
            await previous?.value
            let list = try await body(repository)
            self?.templates = list
        }
        lastChange = Task { _ = try? await work.value }
        return work
    }
}
