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
    private var topologyRefreshNeeded: Bool

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
        topologyRefreshNeeded = true
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
        guard let ref = refByUUID[kind]?[uuid] else { return }
        uuidByRef[kind]?.removeValue(forKey: ref)
        refByUUID[kind]?.removeValue(forKey: uuid)
    }

    /// Resolves a ref back to the object identity it was minted for.
    ///
    /// `tab:N` refs are accepted as aliases for `surface:N` in tab-facing
    /// APIs, matching the legacy resolver.
    ///
    /// - Parameter ref: The handle ref to resolve.
    /// - Returns: The object identity, or `nil` for an unknown ref.
    public func uuid(forRef ref: String) -> UUID? {
        for kind in ControlHandleKind.allCases {
            if let id = uuidByRef[kind]?[ref] {
                return id
            }
        }
        // Tab refs are aliases for surface refs in tab-facing APIs.
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("tab:"),
           let ordinal = Int(trimmed.replacingOccurrences(of: "tab:", with: "")),
           let id = uuidByRef[.surface]?["surface:\(ordinal)"] {
            return id
        }
        return nil
    }

    /// Returns whether a fallback topology refresh is currently needed.
    ///
    /// Membership notifications from the app invalidate the completed claim,
    /// so a repeated stale opaque ref does not rescan the entire app on every
    /// poll. Ref minting itself does not reopen the claim: the command that
    /// minted a ref already made that ref resolvable.
    ///
    public var needsTopologyRefresh: Bool { topologyRefreshNeeded }

    /// Records that the live topology has been swept.
    public mutating func markTopologyRefreshCompleted() {
        topologyRefreshNeeded = false
    }

    /// Reopens the fallback refresh claim after an external topology mutation.
    public mutating func invalidateTopologyRefresh() {
        topologyRefreshNeeded = true
    }
}
