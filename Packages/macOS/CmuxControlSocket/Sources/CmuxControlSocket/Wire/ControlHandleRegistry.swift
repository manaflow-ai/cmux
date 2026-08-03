public import Foundation

/// Mints and resolves the stable `kind:N` handle refs the v2 protocol hands
/// to callers (was the `v2NextHandleOrdinal`/`v2RefByUUID`/`v2UUIDByRef`
/// dictionaries + `v2EnsureHandleRef`/`v2ResolveHandleRef` on
/// `TerminalController`).
///
/// A plain value type; the owner provides isolation (legacy: main-actor
/// state on the controller).
public struct ControlHandleRegistry: Sendable {
    private var nextOrdinal: [ControlHandleKind: Int]
    private var refByUUID: [ControlHandleKind: [UUID: String]]
    private var uuidByRef: [ControlHandleKind: [String: UUID]]

    /// Creates an empty registry with all ordinals starting at 1.
    public init() {
        var ordinals: [ControlHandleKind: Int] = [:]
        var byUUID: [ControlHandleKind: [UUID: String]] = [:]
        var byRef: [ControlHandleKind: [String: UUID]] = [:]
        for kind in ControlHandleKind.allCases {
            ordinals[kind] = 1
            byUUID[kind] = [:]
            byRef[kind] = [:]
        }
        nextOrdinal = ordinals
        refByUUID = byUUID
        uuidByRef = byRef
    }

    /// Returns the existing ref for an object, minting the next
    /// `kind:ordinal` ref on first sight.
    ///
    /// - Parameters:
    ///   - kind: The handle kind.
    ///   - uuid: The object identity.
    /// - Returns: The stable ref string.
    public mutating func ensureRef(kind: ControlHandleKind, uuid: UUID) -> String {
        if let existing = refByUUID[kind]?[uuid] {
            return existing
        }
        let next = nextOrdinal[kind] ?? 1
        let ref = "\(kind.rawValue):\(next)"
        refByUUID[kind, default: [:]][uuid] = ref
        uuidByRef[kind, default: [:]][ref] = uuid
        nextOrdinal[kind] = next + 1
        return ref
    }

    /// Forgets the ref minted for an object (e.g. when a surface closes).
    ///
    /// Ordinals are never reused: a later `ensureRef` for the same identity
    /// mints a fresh ref, matching the legacy cleanup semantics.
    ///
    /// - Parameters:
    ///   - kind: The handle kind.
    ///   - uuid: The object identity to forget.
    public mutating func removeRef(kind: ControlHandleKind, uuid: UUID) {
        if let ref = refByUUID[kind]?[uuid] {
            uuidByRef[kind]?.removeValue(forKey: ref)
        }
        refByUUID[kind]?.removeValue(forKey: uuid)
    }

    /// The kinds an identity has been minted a ref for.
    ///
    /// A raw UUID carries no kind on the wire, but once the registry has handed
    /// out a ref for it, its kind is known: a UUID minted only as `.surface` and
    /// then supplied as `group_id` is provably the wrong kind, not merely an
    /// unrecognized one. Empty means the registry has never seen this identity,
    /// so its kind is genuinely unknown.
    ///
    /// - Parameter uuid: The object identity.
    /// - Returns: Every kind this identity has a minted ref for.
    public func mintedKinds(for uuid: UUID) -> Set<ControlHandleKind> {
        var kinds: Set<ControlHandleKind> = []
        for kind in ControlHandleKind.allCases where refByUUID[kind]?[uuid] != nil {
            kinds.insert(kind)
        }
        return kinds
    }

    /// Resolves a ref back to the object identity it was minted for.
    ///
    /// `tab:N` refs are accepted as aliases for `surface:N` in tab-facing
    /// APIs, matching the legacy resolver.
    ///
    /// - Parameter ref: The handle ref to resolve.
    /// - Returns: The object identity, or `nil` for an unknown ref.
    public func uuid(forRef ref: String) -> UUID? {
        uuid(forRef: ref, kinds: ControlHandleKind.allCases)
    }

    /// Resolves a ref back to the object identity it was minted for, but only
    /// when that identity was minted for one of `kinds`.
    ///
    /// Routing params carry an expected kind (`group_id` means a workspace
    /// group, `pane_id` means a pane), and an unrestricted search lets a
    /// wrong-kind ref resolve to some unrelated object, miss its lookup, and
    /// degrade to the active window
    /// (https://github.com/manaflow-ai/cmux/issues/9424).
    ///
    /// `tab:N` is still accepted as the wire alias for `surface:N` whenever
    /// `.surface` is an accepted kind.
    ///
    /// - Parameters:
    ///   - ref: The handle ref to resolve.
    ///   - kinds: The kinds the caller will accept.
    /// - Returns: The object identity, or `nil` for an unknown or wrong-kind ref.
    public func uuid(forRef ref: String, kinds: [ControlHandleKind]) -> UUID? {
        for kind in kinds {
            if let id = uuidByRef[kind]?[ref] {
                return id
            }
        }
        // Tab refs are aliases for surface refs in tab-facing APIs.
        guard kinds.contains(.surface) else { return nil }
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("tab:"),
           let ordinal = Int(trimmed.replacingOccurrences(of: "tab:", with: "")),
           let id = uuidByRef[.surface]?["surface:\(ordinal)"] {
            return id
        }
        return nil
    }
}
