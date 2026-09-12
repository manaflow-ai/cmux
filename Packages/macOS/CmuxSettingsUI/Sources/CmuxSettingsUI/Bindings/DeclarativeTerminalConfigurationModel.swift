import CmuxFoundation
import CmuxSettings
import Foundation
import Observation

/// The single observable owner for declarative terminal configuration.
///
/// JSON and legacy UserDefaults values are projected into one complete
/// ``DeclarativeTerminalConfiguration/Snapshot``. Workspace and terminal
/// creation paths receive this model as an immutable-snapshot provider, so no
/// secondary cache can fall back to stale schema defaults.
@MainActor
@Observable
public final class DeclarativeTerminalConfigurationModel:
    DeclarativeTerminalConfigurationProviding
{
    private let jsonStore: JSONConfigStore
    private let userDefaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog
    private let reader: DeclarativeTerminalConfigurationReader
    public private(set) var hasInitialSnapshot = false
    private var initialSnapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private var observationTasks = MainActorTaskStore<String>()
    private var saveTasks = MainActorTaskStore<String>()
    private var fixedPathObservationTasks = MainActorTaskStore<String>()
    private var fixedPathWatcher: FileWatcher?
    private var fixedPathWatchPath: String?
    private var authoritativeSnapshot: (
        revision: UInt64,
        terminal: DeclarativeTerminalConfiguration.Snapshot
    )?

    private struct PendingWrites: Sendable {
        var workingDirectoryPolicy: (id: UUID, value: NewSurfaceWorkingDirectoryPolicy)?
        var workingDirectoryPath: (id: UUID, value: String)?
        var shellStartupMode: (id: UUID, value: ShellStartupMode)?
        var shellStartupCommand: (id: UUID, value: String)?
    }

    private var pendingWrites = PendingWrites()

    /// The latest complete, presence-preserving terminal configuration,
    /// including pending writes while they are persisted.
    public private(set) var values = DeclarativeTerminalConfiguration.Snapshot()

    /// The configuration URL represented by ``values``.
    public let fileURL: URL

    /// Protocol projection used by workspace and terminal creation paths.
    public var snapshot: DeclarativeTerminalConfiguration.Snapshot { values }

    /// Creates a model over the stores owned by one ``SettingsRuntime``.
    ///
    /// - Parameters:
    ///   - jsonStore: Actor-backed `cmux.json` store.
    ///   - userDefaultsStore: Legacy compatibility settings store.
    ///   - catalog: Shared setting declarations.
    ///   - errorLog: Destination for save failures.
    ///   - reader: Actor-backed JSON decoder and path validator.
    ///   - fileURL: Optional identity override for tests; defaults to the JSON
    ///     store's URL.
    public init(
        jsonStore: JSONConfigStore,
        userDefaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        reader: DeclarativeTerminalConfigurationReader = DeclarativeTerminalConfigurationReader(),
        fileURL: URL? = nil
    ) {
        self.jsonStore = jsonStore
        self.userDefaultsStore = userDefaultsStore
        self.catalog = catalog
        self.errorLog = errorLog
        self.reader = reader
        self.fileURL = (fileURL ?? jsonStore.fileURL).standardizedFileURL
    }

    /// Waits until the first authoritative JSON/UserDefaults snapshot is
    /// published. Creation paths use this to avoid starting a terminal from
    /// schema defaults before the observer has read the user's file.
    public func waitForInitialSnapshot() async {
        guard !hasInitialSnapshot else { return }
        // Each caller gets its own continuation. A shared AsyncStream iterator
        // is single-consumer and cannot safely serve concurrent window starts.
        await withCheckedContinuation { continuation in
            if hasInitialSnapshot {
                continuation.resume()
            } else {
                initialSnapshotWaiters.append(continuation)
            }
        }
    }

    /// Starts one cancellable observation owner. Repeated calls are idempotent.
    public func startObserving() {
        guard !observationTasks.contains("observation") else { return }
        observationTasks.replaceOnMainActor("observation") { [weak self] in
            guard let self else { return }
            await self.refresh()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in await self?.observeTerminalConfiguration() }
                group.addTask { [weak self] in await self?.observeLegacyInheritance() }
                await group.waitForAll()
            }
        }
    }

    /// Persists a new working-directory policy through the shared JSON store.
    public func setWorkingDirectoryPolicy(_ value: NewSurfaceWorkingDirectoryPolicy) {
        let key = catalog.terminal.newSurfaceWorkingDirectoryPolicy
        let writeID = UUID()
        pendingWrites.workingDirectoryPolicy = (writeID, value)
        updateOptimistically { $0.workingDirectoryPolicy = value }
        saveTasks.replaceOnMainActor("workingDirectoryPolicy") { [weak self] in
            guard let self else { return }
            do {
                try await self.jsonStore.set(value, for: key)
                guard !Task.isCancelled,
                      self.pendingWrites.workingDirectoryPolicy?.id == writeID else { return }
                self.pendingWrites.workingDirectoryPolicy = nil
                await self.refresh()
            } catch {
                guard self.pendingWrites.workingDirectoryPolicy?.id == writeID else { return }
                self.pendingWrites.workingDirectoryPolicy = nil
                self.errorLog.recordSaveFailure(keyID: key.id)
                await self.refresh()
            }
        }
    }

    /// Persists a fixed working-directory draft through the shared JSON store.
    public func setWorkingDirectoryPath(_ value: String) {
        let key = catalog.terminal.newSurfaceWorkingDirectoryPath
        let writeID = UUID()
        pendingWrites.workingDirectoryPath = (writeID, value)
        updateOptimistically { $0.workingDirectoryPath = value }
        saveTasks.replaceOnMainActor("workingDirectoryPath") { [weak self] in
            guard let self else { return }
            do {
                try await self.jsonStore.set(value, for: key)
                guard !Task.isCancelled,
                      self.pendingWrites.workingDirectoryPath?.id == writeID else { return }
                self.pendingWrites.workingDirectoryPath = nil
                await self.refresh()
            } catch {
                guard self.pendingWrites.workingDirectoryPath?.id == writeID else { return }
                self.pendingWrites.workingDirectoryPath = nil
                self.errorLog.recordSaveFailure(keyID: key.id)
                await self.refresh()
            }
        }
    }

    /// Persists the shell startup mode through the shared JSON store.
    public func setShellStartupMode(_ value: ShellStartupMode) {
        let key = catalog.terminal.shellStartupMode
        let writeID = UUID()
        pendingWrites.shellStartupMode = (writeID, value)
        updateOptimistically { $0.shellStartupMode = value }
        saveTasks.replaceOnMainActor("shellStartupMode") { [weak self] in
            guard let self else { return }
            do {
                try await self.jsonStore.set(value, for: key)
                guard !Task.isCancelled,
                      self.pendingWrites.shellStartupMode?.id == writeID else { return }
                self.pendingWrites.shellStartupMode = nil
                await self.refresh()
            } catch {
                guard self.pendingWrites.shellStartupMode?.id == writeID else { return }
                self.pendingWrites.shellStartupMode = nil
                self.errorLog.recordSaveFailure(keyID: key.id)
                await self.refresh()
            }
        }
    }

    /// Persists a normalized shell startup command through the shared store.
    public func setShellStartupCommand(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = catalog.terminal.shellStartupCommand
        let writeID = UUID()
        pendingWrites.shellStartupCommand = (writeID, normalized)
        updateOptimistically { $0.shellStartupCommand = normalized }
        saveTasks.replaceOnMainActor("shellStartupCommand") { [weak self] in
            guard let self else { return }
            do {
                try await self.jsonStore.set(normalized, for: key)
                guard !Task.isCancelled,
                      self.pendingWrites.shellStartupCommand?.id == writeID else { return }
                self.pendingWrites.shellStartupCommand = nil
                await self.refresh()
            } catch {
                guard self.pendingWrites.shellStartupCommand?.id == writeID else { return }
                self.pendingWrites.shellStartupCommand = nil
                self.errorLog.recordSaveFailure(keyID: key.id)
                await self.refresh()
            }
        }
    }

    private func refresh() async {
        async let revision = jsonStore.coherentSnapshot()
        async let legacyInheritanceEnabled = userDefaultsStore.value(
            for: catalog.app.workspaceInheritWorkingDirectory
        )
        await apply(await revision, legacyInheritanceEnabled: await legacyInheritanceEnabled)
    }

    private func observeTerminalConfiguration() async {
        for await revision in jsonStore.snapshots() {
            if Task.isCancelled { return }
            await apply(revision)
        }
    }

    func apply(
        _ revision: JSONConfigStoreSnapshot,
        legacyInheritanceEnabled: Bool? = nil
    ) async {
        let terminal = await reader.decode(revision)
        guard !Task.isCancelled else { return }
        if let authoritativeSnapshot, revision.revision < authoritativeSnapshot.revision {
            publish(
                authoritativeSnapshot.terminal,
                legacyInheritanceEnabled: values.legacyInheritanceEnabled
            )
            return
        }
        authoritativeSnapshot = (revision.revision, terminal)
        publish(
            terminal,
            legacyInheritanceEnabled: legacyInheritanceEnabled ?? values.legacyInheritanceEnabled
        )
    }

    private func observeLegacyInheritance() async {
        for await value in userDefaultsStore.values(for: catalog.app.workspaceInheritWorkingDirectory) {
            if Task.isCancelled { return }
            var updated = values
            updated.legacyInheritanceEnabled = value
            values = updated
        }
    }

    private func publish(
        _ terminal: DeclarativeTerminalConfiguration.Snapshot,
        legacyInheritanceEnabled: Bool? = nil
    ) {
        var complete = terminal
        if let legacyInheritanceEnabled {
            complete.legacyInheritanceEnabled = legacyInheritanceEnabled
        }
        reconcilePendingWrites(with: &complete)
        values = complete
        configureFixedPathWatcher(for: complete)
        guard !hasInitialSnapshot else { return }
        hasInitialSnapshot = true
        let waiters = initialSnapshotWaiters
        initialSnapshotWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func updateOptimistically(
        _ update: (inout DeclarativeTerminalConfiguration.Snapshot) -> Void
    ) {
        let previousFixedPath = values.workingDirectoryPolicy == .fixedPath
            ? values.expandedWorkingDirectoryPath
            : nil
        var updated = values
        update(&updated)
        let updatedFixedPath = updated.workingDirectoryPolicy == .fixedPath
            ? updated.expandedWorkingDirectoryPath
            : nil
        if previousFixedPath != updatedFixedPath {
            updated.fixedPathIsUsable = false
        }
        values = updated
        configureFixedPathWatcher(for: updated)
    }

    private func reconcilePendingWrites(
        with snapshot: inout DeclarativeTerminalConfiguration.Snapshot
    ) {
        if let pending = pendingWrites.workingDirectoryPolicy {
            if snapshot.workingDirectoryPolicy == pending.value {
                pendingWrites.workingDirectoryPolicy = nil
            } else {
                snapshot.workingDirectoryPolicy = pending.value
                snapshot.fixedPathIsUsable = false
            }
        }
        if let pending = pendingWrites.workingDirectoryPath {
            if snapshot.workingDirectoryPath == pending.value {
                pendingWrites.workingDirectoryPath = nil
            } else {
                snapshot.workingDirectoryPath = pending.value
                snapshot.fixedPathIsUsable = false
            }
        }
        if let pending = pendingWrites.shellStartupMode {
            if snapshot.shellStartupMode == pending.value {
                pendingWrites.shellStartupMode = nil
            } else {
                snapshot.shellStartupMode = pending.value
            }
        }
        if let pending = pendingWrites.shellStartupCommand {
            if snapshot.shellStartupCommand == pending.value {
                pendingWrites.shellStartupCommand = nil
            } else {
                snapshot.shellStartupCommand = pending.value
            }
        }
    }

    /// Watches the configured fixed path's ancestor and revalidates it off the
    /// main actor when the filesystem changes. Spawn paths consume only the
    /// latest cached result, so a deleted directory fails closed without a
    /// synchronous metadata lookup during workspace creation.
    private func configureFixedPathWatcher(
        for terminal: DeclarativeTerminalConfiguration.Snapshot
    ) {
        let desiredPath = terminal.workingDirectoryPolicy == .fixedPath
            ? terminal.expandedWorkingDirectoryPath
            : nil
        guard desiredPath != fixedPathWatchPath else { return }

        fixedPathObservationTasks.cancel("fixedPath")
        fixedPathWatcher = nil
        fixedPathWatchPath = desiredPath

        guard let desiredPath else { return }
        let watcher = FileWatcher(path: desiredPath)
        fixedPathWatcher = watcher
        let reader = self.reader
        fixedPathObservationTasks.replaceOnMainActor("fixedPath") { [weak self, watcher, reader] in
            let isInitiallyUsable = await reader.validateFixedPath(desiredPath)
            guard !Task.isCancelled else { return }
            if let self {
                self.applyFixedPathValidation(isInitiallyUsable, for: desiredPath)
            }
            for await _ in watcher.events {
                guard !Task.isCancelled else { return }
                let isUsable = await reader.validateFixedPath(desiredPath)
                guard !Task.isCancelled, let self else { return }
                self.applyFixedPathValidation(isUsable, for: desiredPath)
            }
        }
    }

    private func applyFixedPathValidation(_ isUsable: Bool, for path: String) {
        if authoritativeSnapshot?.terminal.workingDirectoryPolicy == .fixedPath,
           authoritativeSnapshot?.terminal.expandedWorkingDirectoryPath == path {
            authoritativeSnapshot?.terminal.fixedPathIsUsable = isUsable
        }
        guard fixedPathWatchPath == path,
              values.workingDirectoryPolicy == .fixedPath,
              values.expandedWorkingDirectoryPath == path,
              values.fixedPathIsUsable != isUsable else {
            return
        }
        var updated = values
        updated.fixedPathIsUsable = isUsable
        values = updated
    }
}
