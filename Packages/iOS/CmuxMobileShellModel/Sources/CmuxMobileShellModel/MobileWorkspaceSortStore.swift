public import Foundation

/// Device-local sort preference for the aggregated "All Computers" workspace
/// list, persisted in an injected `UserDefaults`.
///
/// The sort is a per-device presentation choice, never sent to a Mac: phones
/// and Macs may order the same workspaces differently. The backing
/// `UserDefaults` is injected so the store is testable without touching
/// `.standard` (mirroring ``MobileWorkspaceGroupCollapseStore``); the app
/// constructs it at the composition root with `UserDefaults.standard`.
public struct MobileWorkspaceSortStore: Sendable {
    /// The defaults key under which the mode + computer order payload is stored.
    public static let defaultsKey = "dev.cmux.mobile.workspaceList.sort.v1"
    private static let currentComputerIdentityVersion = 2

    /// The persisted shape. `mode` stays a raw string so a value written by a
    /// newer build with more modes still decodes here (reading as `.automatic`
    /// without being rewritten).
    private struct Payload: Codable {
        var mode: String
        var computerPriority: [String]
        var computerIdentityVersion: Int?
    }

    // UserDefaults is Apple-documented thread-safe; OK to hold nonisolated.
    private nonisolated(unsafe) let defaults: UserDefaults
    private var payload: Payload

    /// Create a store backed by the given defaults.
    /// - Parameter defaults: The persistence store. Inject a suite-scoped
    ///   `UserDefaults` in tests; the app passes `.standard`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        } else {
            payload = Payload(
                mode: MobileWorkspaceSortMode.automatic.rawValue,
                computerPriority: [],
                computerIdentityVersion: Self.currentComputerIdentityVersion
            )
        }
    }

    /// The persisted sort mode; unknown stored values read as `.automatic`.
    public var mode: MobileWorkspaceSortMode {
        MobileWorkspaceSortMode(rawValue: payload.mode) ?? .automatic
    }

    /// Device-plus-build pairing ids in the user's chosen computer order,
    /// highest priority first. Legacy bare device ids remain readable. Applied
    /// only while ``mode`` is `.computerPriority`; ids that no longer match a
    /// live computer are ignored by the aggregation, and kept here so a
    /// temporarily offline computer retains its slot.
    public var computerPriority: [String] { payload.computerPriority }

    /// Whether a pre-build-scoped order still needs one migration after the
    /// paired-Mac rows are available to disambiguate bare device ids.
    public var needsComputerIdentityMigration: Bool {
        (payload.computerIdentityVersion ?? 1) < Self.currentComputerIdentityVersion
    }

    /// Persist a mode choice. No-op when unchanged.
    public mutating func setMode(_ mode: MobileWorkspaceSortMode) {
        guard payload.mode != mode.rawValue else { return }
        payload.mode = mode.rawValue
        persist()
    }

    /// Persist a user computer order. No-op when unchanged.
    public mutating func setComputerPriority(_ computerIDs: [String]) {
        guard payload.computerPriority != computerIDs else { return }
        payload.computerPriority = computerIDs
        payload.computerIdentityVersion = Self.currentComputerIdentityVersion
        persist()
    }

    /// Persist a one-time upgrade of the legacy device-only priority format.
    public mutating func migrateLegacyComputerPriority(_ computerIDs: [String]) {
        guard needsComputerIdentityMigration else { return }
        payload.computerPriority = computerIDs
        payload.computerIdentityVersion = Self.currentComputerIdentityVersion
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
