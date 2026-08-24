import CmuxFoundation
import CmuxSettings
import Foundation
import Observation

/// Runtime-owned snapshot and mutation surface for declarative terminal
/// settings. The model keeps JSON presence and the legacy compatibility value
/// together so Settings cannot render a draft from one source while runtime
/// resolution uses another.
@MainActor
@Observable
public final class DeclarativeTerminalConfigurationModel {
    /// The values currently observed from `cmux.json` and legacy defaults.
    public struct Snapshot: Equatable, Sendable {
        /// The authored policy, or `nil` when absent or invalid.
        public var workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy?
        /// The fixed-path setting, defaulting to an empty string.
        public var workingDirectoryPath: String
        /// The configured shell mode.
        public var shellStartupMode: ShellStartupMode
        /// The configured startup command, trimmed and empty when absent.
        public var shellStartupCommand: String
        /// The legacy inheritance value used only when policy is absent.
        public var legacyInheritanceEnabled: Bool

        /// Creates a safe initial snapshot.
        public init(
            workingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy? = nil,
            workingDirectoryPath: String = "",
            shellStartupMode: ShellStartupMode = .login,
            shellStartupCommand: String = "",
            legacyInheritanceEnabled: Bool = true
        ) {
            self.workingDirectoryPolicy = workingDirectoryPolicy
            self.workingDirectoryPath = workingDirectoryPath
            self.shellStartupMode = shellStartupMode
            self.shellStartupCommand = shellStartupCommand
            self.legacyInheritanceEnabled = legacyInheritanceEnabled
        }

        /// The policy runtime uses, including the legacy fallback.
        public var effectiveWorkingDirectoryPolicy: NewSurfaceWorkingDirectoryPolicy {
            workingDirectoryPolicy
                ?? (legacyInheritanceEnabled ? .inheritActivePane : .workspaceRoot)
        }
    }

    private let jsonStore: JSONConfigStore
    private let userDefaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog
    private let errorLog: SettingsErrorLog
    private let cache: DeclarativeTerminalConfigurationCache
    private let reader: DeclarativeTerminalConfigurationReader
    private let fileURL: URL
    private var observationTasks = MainActorTaskStore<String>()
    private var saveTasks = MainActorTaskStore<String>()
    private var snapshotRevision: UInt64 = 0

    /// The single presence-preserving view of the shared JSON authority.
    /// JSON values come from the injected cache; only the legacy fallback is
    /// maintained locally until its UserDefaults stream changes.
    public var values: Snapshot {
        _ = snapshotRevision
        let raw = cache.snapshot(fileURL: fileURL)
        return Snapshot(
            workingDirectoryPolicy: raw.workingDirectoryPolicy,
            workingDirectoryPath: raw.workingDirectoryPath,
            shellStartupMode: raw.shellStartupMode,
            shellStartupCommand: raw.shellStartupCommand,
            legacyInheritanceEnabled: legacyInheritanceEnabled
        )
    }
    private var legacyInheritanceEnabled = true

    /// Creates a model over the stores owned by one ``SettingsRuntime``.
    public init(
        jsonStore: JSONConfigStore,
        userDefaultsStore: UserDefaultsSettingsStore,
        catalog: SettingCatalog,
        errorLog: SettingsErrorLog,
        cache: DeclarativeTerminalConfigurationCache,
        reader: DeclarativeTerminalConfigurationReader = DeclarativeTerminalConfigurationReader(),
        fileURL: URL? = nil
    ) {
        self.jsonStore = jsonStore
        self.userDefaultsStore = userDefaultsStore
        self.catalog = catalog
        self.errorLog = errorLog
        self.cache = cache
        self.reader = reader
        self.fileURL = fileURL ?? jsonStore.fileURL
    }

    deinit {
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
    /// The long-lived coherent snapshot observer is the single publisher of
    /// ``values`` and the runtime cache. Keeping writes out of that publisher's
    /// path prevents an observer read and a save-triggered refresh from racing
    /// and publishing an older file revision after a newer one.
    public func setWorkingDirectoryPolicy(_ value: NewSurfaceWorkingDirectoryPolicy) {
        let key = catalog.terminal.newSurfaceWorkingDirectoryPolicy
        saveTasks.replaceOnMainActor("workingDirectoryPolicy") { [weak self] in
            guard let self else { return }
            do {
                try await self.jsonStore.set(value, for: key)
            } catch {
                self.errorLog.recordSaveFailure(keyID: key.id)
            }
        }
    }

    /// Persists and reconciles the fixed working-directory draft.
    public func setWorkingDirectoryPath(_ value: String) {
        let key = catalog.terminal.newSurfaceWorkingDirectoryPath
        saveTasks.replaceOnMainActor("workingDirectoryPath") { [weak self] in
            guard let self else { return }
            do {
                try await self.jsonStore.set(value, for: key)
            } catch {
                self.errorLog.recordSaveFailure(keyID: key.id)
            }
        }
    }

    /// Persists the shell startup mode through the shared JSON store.
    public func setShellStartupMode(_ value: ShellStartupMode) {
        let key = catalog.terminal.shellStartupMode
        saveTasks.replaceOnMainActor("shellStartupMode") { [weak self] in
            guard let self else { return }
            do {
                try await self.jsonStore.set(value, for: key)
            } catch {
                self.errorLog.recordSaveFailure(keyID: key.id)
            }
        }
    }

    /// Persists and reconciles the shell startup command draft.
    public func setShellStartupCommand(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = catalog.terminal.shellStartupCommand
        saveTasks.replaceOnMainActor("shellStartupCommand") { [weak self] in
            guard let self else { return }
            do {
                try await self.jsonStore.set(normalized, for: key)
            } catch {
                self.errorLog.recordSaveFailure(keyID: key.id)
            }
        }
    }

    private func refresh() async {
        await refreshJSON()
        legacyInheritanceEnabled = await userDefaultsStore.value(
            for: catalog.app.workspaceInheritWorkingDirectory
        )
        snapshotRevision &+= 1
    }

    private func refreshJSON() async {
        let revision = await jsonStore.coherentSnapshot()
        let terminal = await reader.decode(revision)
        cache.replace(terminal, fileURL: fileURL)
        snapshotRevision &+= 1
    }

    private func observeTerminalConfiguration() async {
        for await revision in jsonStore.snapshots() {
            if Task.isCancelled { return }
            let terminal = await reader.decode(revision)
            cache.replace(terminal, fileURL: fileURL)
            snapshotRevision &+= 1
        }
    }

    private func observeLegacyInheritance() async {
        for await value in userDefaultsStore.values(for: catalog.app.workspaceInheritWorkingDirectory) {
            if Task.isCancelled { return }
            legacyInheritanceEnabled = value
            snapshotRevision &+= 1
        }
    }

}
