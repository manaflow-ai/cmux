import Foundation
public import Observation

/// The single owner of one profile's per-site permission decisions, shared
/// by both engines. Engines read it before asking the user and write the
/// answer back; Page Info and Site settings edit it. Decisions persist per
/// profile and apply to every later request from that origin.
@Observable
public final class SitePermissionStore {
    public let profile: BrowserProfileID
    /// origin -> explicit decisions. A missing entry means the default.
    public private(set) var decisions: [String: [SitePermissionKind: SitePermissionSetting]] = [:]
    public private(set) var isLoaded = false

    @ObservationIgnored private let persistence: any SitePermissionPersistence
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var editedBeforeLoad: Set<String> = []

    public init(profile: BrowserProfileID, persistence: any SitePermissionPersistence) {
        self.profile = profile
        self.persistence = persistence
        loadTask = Task { [weak self, persistence] in
            let snapshot = await persistence.load()
            self?.finishLoading(snapshot)
        }
    }

    /// Returns once the stored decisions are in memory.
    public func whenLoaded() async {
        await loadTask?.value
    }

    private func finishLoading(_ snapshot: SitePermissionSnapshot) {
        // Decisions made before the file arrived win over stored ones.
        for (origin, stored) in snapshot.origins where !editedBeforeLoad.contains(origin) {
            decisions[origin] = stored
        }
        editedBeforeLoad.removeAll()
        isLoaded = true
    }

    // MARK: Reading

    /// The effective setting: the stored decision, else the default.
    public func setting(_ kind: SitePermissionKind, for origin: String) -> SitePermissionSetting {
        decisions[origin]?[kind] ?? kind.defaultSetting
    }

    /// The stored decision, nil when the site uses the default.
    public func decision(_ kind: SitePermissionKind, for origin: String) -> SitePermissionSetting? {
        decisions[origin]?[kind]
    }

    public func state(_ kind: SitePermissionKind, for origin: String) -> SitePermissionState {
        let stored = decision(kind, for: origin)
        return SitePermissionState(kind: kind, setting: stored ?? kind.defaultSetting, isDefault: stored == nil)
    }

    /// Permissions with a stored decision that differs from the default
    /// (what "Reset permissions" clears).
    public func changedKinds(for origin: String) -> Set<SitePermissionKind> {
        Set((decisions[origin] ?? [:]).filter { $0.value != $0.key.defaultSetting }.keys)
    }

    /// Origins with at least one stored decision, sorted.
    public var origins: [String] { decisions.keys.filter { !(decisions[$0]?.isEmpty ?? true) }.sorted() }

    // MARK: Writing

    /// Stores `setting` for `kind` on `origin`. The default value clears the
    /// decision, as choosing "Ask (default)" does.
    public func set(_ setting: SitePermissionSetting, _ kind: SitePermissionKind, for origin: String) {
        var site = decisions[origin] ?? [:]
        if setting == kind.defaultSetting { site[kind] = nil } else { site[kind] = setting }
        update(origin, site)
    }

    /// Clears every decision of `origin` ("Reset permissions").
    public func reset(origin: String) {
        guard decisions[origin] != nil else { return }
        update(origin, [:])
    }

    private func update(_ origin: String, _ site: [SitePermissionKind: SitePermissionSetting]) {
        let normalized = site.isEmpty ? nil : site
        guard decisions[origin] != normalized else { return }
        decisions[origin] = normalized
        if !isLoaded { editedBeforeLoad.insert(origin) }
        let snapshot = SitePermissionSnapshot(origins: decisions)
        let persistence = persistence
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            await persistence.save(snapshot)
        }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Waits for pending writes (tests, quit).
    public func flush() async {
        await saveTask?.value
    }
}
