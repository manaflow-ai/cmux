public import Foundation
public import Observation
package import CmuxNextCompat

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
        package var loading = false
        package var overrides: [String: TunableValue] = [:]
        package var descriptors: [String: TunableDescriptor] = [:]
        package var revision = 0
        /// One Observation key path per key, made once (at `register`, at launch): a key path with
        /// a subscript argument is a new object (and, the first time, a runtime type lookup) per
        /// call, 5-10 ms cold on a read path such as a tab switch (cx-8w027.25).
        package var keyPaths: [String: KeyPath<TunableStore, Int> & Sendable] = [:]
        /// Keys a tunable had before (`registerRename`): the old key's file value, mapped, when the file
        /// has no value under the new key.
        package var renames: [String: Rename] = [:]
        /// Keys reset while the file read was pending (setting a choice back to its default is a reset):
        /// the file's value for them is not applied when the read lands.
        package var cleared: Set<String> = []

        package init(loading: Bool = false, overrides: [String: TunableValue] = [:], descriptors: [String: TunableDescriptor] = [:], revision: Int = 0, keyPaths: [String: KeyPath<TunableStore, Int> & Sendable] = [:]) {
            self.loading = loading
            self.overrides = overrides
            self.descriptors = descriptors
            self.revision = revision
            self.keyPaths = keyPaths
        }
    }

    package struct Rename: Sendable {
        package let key: String
        package let map: @Sendable (Any) -> Any?
    }

    private let registrar = ObservationRegistrar()
    /// The inert fast path: false in Release and RC, so a read is one
    /// relaxed atomic load there.
    private let active = Atomic<Bool>(false)
    private let state = Mutex(State())
    private let writer = Mutex<TunableFileWriter?>(nil)
    /// The override file `activate` read (nil without one).
    private let file = Mutex<URL?>(nil)

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
            for descriptor in descriptors {
                state.descriptors[descriptor.key] = descriptor
                if state.keyPaths[descriptor.key] == nil { state.keyPaths[descriptor.key] = \TunableStore.[observed: descriptor.key] }
            }
        }
    }

    /// The Observation key path of `key`: made once per key.
    private func keyPath(_ key: String) -> KeyPath<TunableStore, Int> & Sendable {
        state.withLock { state in
            if let made = state.keyPaths[key] { return made }
            let made: KeyPath<TunableStore, Int> & Sendable = \TunableStore.[observed: key]
            state.keyPaths[key] = made
            return made
        }
    }

    /// A tunable that was called `old`: a file that still holds `old` (and not `new`) gives `new` the
    /// value `map` makes of the old one (nil drops it). The next write keeps only `new`.
    public func registerRename(from old: String, to new: String, map: @escaping @Sendable (Any) -> Any?) {
        state.withLock { $0.renames[old] = Rename(key: new, map: map) }
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
        // `active` last (releasing): a reader that sees it also sees the file and the pending read.
        guard let file else { return active.store(true, ordering: .releasing) }
        self.file.withLock { $0 = file }
        writer.withLock { $0 = TunableFileWriter(url: file) }
        state.withLock { $0.loading = true }
        active.store(true, ordering: .releasing)
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
        registrar.access(self, keyPath: keyPath(key))
        return state.withLock { $0.overrides[key] }
    }

    /// The override for `key` as the file holds it, also before `activate`'s read lands: while that
    /// read is pending, the file is read here (blocking). For a setting read once at a launch step
    /// that cannot wait for the main actor's load (Chromium's launch switches, `CEFRuntime`).
    /// The value read is applied to the store at once (the load's later merge keeps it, as it keeps
    /// any change made since launch), so what the caller launched with is what the store reports;
    /// a `set` that lands during the read wins, and the caller gets that value.
    public func settledOverride(_ key: String) -> TunableValue? {
        guard active.load(ordering: .acquiring) else { return nil }
        let pending = state.withLock { state -> Bool in state.loading && state.overrides[key] == nil && !state.cleared.contains(key) }
        guard pending, let url = file.withLock({ $0 }) else { return state.withLock { $0.overrides[key] } }
        // concurrency-allow: one small Debug Settings file, read once when Chromium starts and only while the
        // store's own read of it is still pending (DEV and NIGHTLY)
        if let value = validate(TunableFile.readRaw(url))[key] { merge([key: value]) }
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
        let present = state.withLock { state in
            if state.loading { state.cleared.formUnion(keys) }
            return keys.filter { state.overrides[$0] != nil }
        }
        guard !present.isEmpty else { return }
        mutate(present) { overrides in present.forEach { overrides[$0] = nil } }
    }

    /// Removes every override.
    public func resetAll() {
        // While the file read is pending its keys are not in `overrides` yet: every registered key is
        // reset, so none of the file's values comes back when the read lands.
        reset(state.withLock { $0.loading ? Array(Set($0.overrides.keys).union($0.descriptors.keys)) : Array($0.overrides.keys) })
    }

    /// Merges a file's raw values (`TunableFile.decode`) into the
    /// overrides. A key already set wins (a change made since launch);
    /// unknown keys and values that do not fit are dropped.
    public func load(raw values: [String: Any]) {
        merge(validate(values))
    }

    /// The file's values that fit their descriptors, clamped.
    private func validate(_ raw: [String: Any]) -> [String: TunableValue] {
        state.withLock { state in
            var values = raw
            for (old, rename) in state.renames where values[rename.key] == nil {
                if let value = values[old].flatMap(rename.map) { values[rename.key] = value }
            }
            return values.reduce(into: [String: TunableValue]()) { result, entry in
                guard let descriptor = state.descriptors[entry.key],
                      let value = TunableFile.value(entry.value, as: descriptor.kind),
                      let clamped = descriptor.clamp(value) else { return }
                result[entry.key] = clamped
            }
        }
    }

    @MainActor private func finishLoad(_ values: [String: TunableValue]) {
        let (changedBeforeLoad, kept) = state.withLock { state in
            state.loading = false
            defer { state.cleared = [] }
            return (!state.overrides.isEmpty || !state.cleared.isEmpty, values.filter { !state.cleared.contains($0.key) })
        }
        merge(kept)
        // A change made while the read was pending was held back; write the
        // merged set now.
        if changedBeforeLoad {
            let snapshot = state.withLock { $0.overrides }
            writer.withLock { $0?.write(snapshot) }
        }
    }

    private func merge(_ values: [String: TunableValue]) {
        let fresh = state.withLock { state in values.filter { state.overrides[$0.key] == nil && !state.cleared.contains($0.key) } }
        guard !fresh.isEmpty else { return }
        mutate(Array(fresh.keys), persist: false) { overrides in
            for (key, value) in fresh where overrides[key] == nil { overrides[key] = value }
        }
    }

    /// One observation mutation per key, nested, with `body` inside the last one. A method, not a
    /// recursive local function that captures `body` (Swift 6.3.3's SendNonSendable pass crashed
    /// now and then on such captures in Release).
    private func apply(_ remaining: ArraySlice<String>, _ body: (inout [String: TunableValue]) -> Void) {
        guard let key = remaining.first else {
            registrar.withMutation(of: self, keyPath: \.revision) {
                state.withLock { state in
                    body(&state.overrides)
                    state.revision += 1
                }
            }
            return
        }
        registrar.withMutation(of: self, keyPath: keyPath(key)) { apply(remaining.dropFirst(), body) }
    }

    private func mutate(_ keys: [String], persist: Bool = true, _ body: (inout [String: TunableValue]) -> Void) {
        apply(keys[...], body)
        guard persist else { return }
        guard let snapshot = state.withLock({ $0.loading ? nil : $0.overrides }) else { return }
        writer.withLock { $0?.write(snapshot) }
    }
}
