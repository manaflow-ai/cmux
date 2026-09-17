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

    /// The persisted shape. `mode` stays a raw string so a value written by a
    /// newer build with more modes still decodes here (reading as `.automatic`
    /// without being rewritten).
    private struct Payload: Codable {
        var mode: String
        var computerPriority: [String]
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
                computerPriority: []
            )
        }
    }

    /// The persisted sort mode; unknown stored values read as `.automatic`.
    public var mode: MobileWorkspaceSortMode {
        MobileWorkspaceSortMode(rawValue: payload.mode) ?? .automatic
    }

    /// Mac device ids in the user's chosen computer order, highest priority
    /// first. Applied only while ``mode`` is `.computerPriority`; ids that no
    /// longer match a live computer are ignored by the aggregation, and kept
    /// here so a temporarily offline computer retains its slot.
    public var computerPriority: [String] { payload.computerPriority }

    /// Persist a mode choice. No-op when unchanged.
    public mutating func setMode(_ mode: MobileWorkspaceSortMode) {
        guard payload.mode != mode.rawValue else { return }
        payload.mode = mode.rawValue
        persist()
    }

    /// Persist a user computer order. No-op when unchanged.
    public mutating func setComputerPriority(_ deviceIDs: [String]) {
        guard payload.computerPriority != deviceIDs else { return }
        payload.computerPriority = deviceIDs
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
