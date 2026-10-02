public import Foundation
public import Observation
import Synchronization

/// The live overrides of every tunable. Defaults stay in code; the store
/// holds only what the developer changed in Debug Settings.
///
/// Owner: the config layer of this Mac (OWNERSHIP-PRINCIPLES.md,
/// "Preferences"), client-side only: nothing here reaches the daemon or the
/// workspace store. It is inert until `activate` runs, which the App does in
/// DEV and NIGHTLY builds only, so Release and RC always use the defaults
/// and never read the override file.
///
/// Reads are thread-safe (Motion tokens are read off the main actor) and
/// observable per key: a view that read `drop.overlay.style` re-renders
/// when that key changes, not when another one does.
public nonisolated final class TunableStore: Observable, Sendable {
    public static let shared = TunableStore()

    private struct State {
        /// A file read is pending: writes wait for it, so a change made
        /// before it lands is neither lost to the load nor written without
        /// the file's other values.
        var loading = false
        var overrides: [String: TunableValue] = [:]
        var descriptors: [String: TunableDescriptor] = [:]
        var revision = 0
    }

    private let registrar = ObservationRegistrar()
    /// The inert fast path: false in Release and RC, so a read is one
    /// relaxed atomic load there.
    private let active = Atomic<Bool>(false)
    private let state = Mutex(State())
    private let writer = Mutex<TunableFileWriter?>(nil)

    public init() {}

    // MARK: Observation key paths

    /// Identity of one key for Observation (never read for its value).
    private subscript(observed key: String) -> Int { 0 }

    /// Changes on every write; the window observes it to refresh lists.
    public var revision: Int {
        registrar.access(self, keyPath: \.revision)
        return state.withLock { $0.revision }
    }

    // MARK: Lifecycle

    /// Whether overrides apply (DEV and NIGHTLY after launch).
    public var isActive: Bool { active.load(ordering: .relaxed) }

    /// Declares the tunables the window lists and the store accepts.
    public func register(_ descriptors: [TunableDescriptor]) {
        state.withLock { state in
            for descriptor in descriptors { state.descriptors[descriptor.key] = descriptor }
        }
    }

    public var descriptors: [TunableDescriptor] {
        state.withLock { Array($0.descriptors.values) }
    }

    public func descriptor(for key: String) -> TunableDescriptor? {
        state.withLock { $0.descriptors[key] }
    }

    /// Turns overrides on. With `file`, reads it off the main actor and
    /// applies its values on the main actor (observers are told there),
    /// then writes every later change back, coalesced, off the main actor.
    public func activate(file: URL?) {
        active.store(true, ordering: .relaxed)
        guard let file else { return }
        writer.withLock { $0 = TunableFileWriter(url: file) }
        state.withLock { $0.loading = true }
        Task.detached(priority: .userInitiated) { [weak self] in
            let raw = TunableFile.readRaw(file)
            guard let self else { return }
            let valid = self.validate(raw)
            await MainActor.run { self.finishLoad(valid) }
        }
    }

    // MARK: Reads

    /// The override for `key`, if any. Registers an Observation dependency.
    public func override(_ key: String) -> TunableValue? {
        guard active.load(ordering: .relaxed) else { return nil }
        registrar.access(self, keyPath: \.[observed: key])
        return state.withLock { $0.overrides[key] }
    }

    /// Every override, by key.
    public var overrides: [String: TunableValue] {
        registrar.access(self, keyPath: \.revision)
        return state.withLock { $0.overrides }
    }

    // MARK: Writes

    /// Sets `key` (clamped to its descriptor) or, with nil, resets it.
    /// Returns the stored value, or nil when it was reset or refused (an
    /// unknown key, a value of the wrong type).
    @discardableResult
    public func set(_ key: String, _ value: TunableValue?) -> TunableValue? {
        guard let value else {
            reset([key])
            return nil
        }
        guard let descriptor = descriptor(for: key), let clamped = descriptor.clamp(value) else { return nil }
        mutate([key]) { $0[key] = clamped }
        return clamped
    }

    /// Removes the overrides of `keys`.
    public func reset(_ keys: [String]) {
        let present = state.withLock { state in keys.filter { state.overrides[$0] != nil } }
        guard !present.isEmpty else { return }
        mutate(present) { overrides in present.forEach { overrides[$0] = nil } }
    }

    /// Removes every override.
    public func resetAll() {
        reset(state.withLock { Array($0.overrides.keys) })
    }

    /// Merges a file's raw values (`TunableFile.decode`) into the
    /// overrides. A key already set wins (a change made since launch);
    /// unknown keys and values that do not fit are dropped.
    public func load(raw values: [String: Any]) {
        merge(validate(values))
    }

    /// The file's values that fit their descriptors, clamped.
    private func validate(_ values: [String: Any]) -> [String: TunableValue] {
        state.withLock { state in
            values.reduce(into: [String: TunableValue]()) { result, entry in
                guard let descriptor = state.descriptors[entry.key],
                      let value = TunableFile.value(entry.value, as: descriptor.kind),
                      let clamped = descriptor.clamp(value) else { return }
                result[entry.key] = clamped
            }
        }
    }

    @MainActor private func finishLoad(_ values: [String: TunableValue]) {
        let changedBeforeLoad = state.withLock { state in
            state.loading = false
            return !state.overrides.isEmpty
        }
        merge(values)
        // A change made while the read was pending was held back; write the
        // merged set now.
        if changedBeforeLoad {
            let snapshot = state.withLock { $0.overrides }
            writer.withLock { $0?.write(snapshot) }
        }
    }

    private func merge(_ values: [String: TunableValue]) {
        let fresh = state.withLock { state in values.filter { state.overrides[$0.key] == nil } }
        guard !fresh.isEmpty else { return }
        mutate(Array(fresh.keys), persist: false) { overrides in
            for (key, value) in fresh where overrides[key] == nil { overrides[key] = value }
        }
    }

    private func mutate(_ keys: [String], persist: Bool = true, _ body: (inout [String: TunableValue]) -> Void) {
        func apply(_ remaining: ArraySlice<String>) {
            guard let key = remaining.first else {
                registrar.withMutation(of: self, keyPath: \.revision) {
                    state.withLock { state in
                        body(&state.overrides)
                        state.revision += 1
                    }
                }
                return
            }
            registrar.withMutation(of: self, keyPath: \.[observed: key]) { apply(remaining.dropFirst()) }
        }
        apply(keys[...])
        guard persist else { return }
        guard let snapshot = state.withLock({ $0.loading ? nil : $0.overrides }) else { return }
        writer.withLock { $0?.write(snapshot) }
    }
}
