public import Foundation

/// Reconciles hook, Feed-attention, and process-generation evidence per panel.
public nonisolated struct AgentLifecycleReconciliationState: Sendable {
    private var entriesByPanelId: [UUID: [String: AgentLifecycleEntry]] = [:]

    /// The current legacy lifecycle snapshot consumed by sidebar and hibernation.
    public private(set) var resolvedStatesByPanelId:
        [UUID: [String: AgentLifecycleState]] = [:]

    /// Whether the state contains any hook, attention, or process evidence.
    public var hasEvidence: Bool { !entriesByPanelId.isEmpty }

    /// Panels that currently retain reconciliation evidence.
    public var panelIdsWithEvidence: Set<UUID> { Set(entriesByPanelId.keys) }

    /// Creates an empty reconciliation state.
    public init() {}

    /// Records a hook observation if its process generation is still admissible.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The panel that owns the evidence.
    ///   - lifecycle: The lifecycle reported by the hook.
    ///   - isBuiltIn: Whether the key belongs to a built-in integration.
    ///   - processGeneration: The exact emitting process generation, when known.
    /// - Returns: `true` when the observation was admitted.
    @discardableResult
    public mutating func setHookLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentLifecycleState,
        isBuiltIn: Bool,
        processGeneration: AgentProcessGeneration? = nil
    ) -> Bool {
        var entry = entriesByPanelId[panelId]?[key]
            ?? AgentLifecycleEntry()
        entry.isBuiltIn = entry.isBuiltIn || isBuiltIn
        if let processGeneration,
           entry.liveProcessGeneration == nil,
           let currentGeneration = entry.hook?.processGeneration,
           processGeneration < currentGeneration {
            return false
        }
        guard admit(
            processGeneration: processGeneration,
            into: &entry
        ) else {
            return false
        }
        entry.hook = AgentLifecycleHookObservation(
            lifecycle: lifecycle,
            processGeneration:
                processGeneration ?? entry.liveProcessGeneration
        )
        entry.suppressesLifecycleUntilNextHook = false
        setEntry(entry, key: key, panelId: panelId)
        return true
    }

    /// Starts a Feed-owned needs-input overlay.
    ///
    /// Exact generation evidence older than the current hook is rejected.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The panel that owns the overlay.
    ///   - isBuiltIn: Whether the key belongs to a built-in integration.
    ///   - processGeneration: The exact owning process generation, when known.
    /// - Returns: A token that only the matching conclusion may remove.
    public mutating func beginFeedAttention(
        key: String,
        panelId: UUID,
        isBuiltIn: Bool,
        processGeneration: AgentProcessGeneration? = nil
    ) -> AgentFeedAttentionToken? {
        var entry = entriesByPanelId[panelId]?[key]
            ?? AgentLifecycleEntry()
        entry.isBuiltIn = entry.isBuiltIn || isBuiltIn
        if let processGeneration,
           let hookGeneration = entry.hook?.processGeneration,
           processGeneration < hookGeneration {
            return nil
        }
        guard admit(
            processGeneration: processGeneration,
            into: &entry
        ) else {
            return nil
        }
        let token = AgentFeedAttentionToken(
            processGeneration:
                processGeneration ?? entry.liveProcessGeneration
        )
        entry.feedAttentionTokens.insert(token)
        setEntry(entry, key: key, panelId: panelId)
        return token
    }

    /// Whether a key currently has at least one Feed-owned attention overlay.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The owning panel.
    /// - Returns: `true` when Feed still owns an overlay.
    public func hasFeedAttention(key: String, panelId: UUID) -> Bool {
        entriesByPanelId[panelId]?[key]?.feedAttentionTokens.isEmpty == false
    }

    /// Concludes only the exact Feed-owned overlay represented by a token.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The owning panel.
    ///   - token: The token returned by ``beginFeedAttention(key:panelId:isBuiltIn:processGeneration:)``.
    /// - Returns: `true` when the token was present and removed.
    @discardableResult
    public mutating func endFeedAttention(
        key: String,
        panelId: UUID,
        token: AgentFeedAttentionToken
    ) -> Bool {
        guard var entry = entriesByPanelId[panelId]?[key],
              entry.feedAttentionTokens.contains(token) else {
            return false
        }
        if let processGeneration = token.processGeneration,
           let liveProcessGeneration = entry.liveProcessGeneration,
           processGeneration != liveProcessGeneration {
            return false
        }
        entry.feedAttentionTokens.remove(token)
        setEntry(entry, key: key, panelId: panelId)
        return true
    }

    /// Binds lifecycle evidence to an exact process generation.
    ///
    /// An older generation can never replace newer live, hook, exit, or exact
    /// Feed-attention evidence.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The owning panel.
    ///   - generation: The exact process generation being registered.
    ///   - isBuiltIn: Whether the key belongs to a built-in integration.
    /// - Returns: `true` when the generation was admitted.
    @discardableResult
    public mutating func recordProcessGeneration(
        key: String,
        panelId: UUID,
        generation: AgentProcessGeneration,
        isBuiltIn: Bool
    ) -> Bool {
        var entry = entriesByPanelId[panelId]?[key]
            ?? AgentLifecycleEntry()
        entry.isBuiltIn = entry.isBuiltIn || isBuiltIn

        if let live = entry.liveProcessGeneration, generation < live {
            return false
        }
        if let exited = entry.exitedProcessGeneration,
           generation <= exited {
            return false
        }
        if let hookGeneration = entry.hook?.processGeneration,
           generation < hookGeneration {
            return false
        }
        if let attentionGeneration = entry.feedAttentionTokens.compactMap(\.processGeneration).max(),
           generation < attentionGeneration {
            return false
        }

        if entry.liveProcessGeneration != generation {
            entry.suppressesLifecycleUntilNextHook = false
        }
        entry.feedAttentionTokens = Set(
            entry.feedAttentionTokens.filter {
                $0.processGeneration == nil
                    || $0.processGeneration == generation
            }
        )
        if var hook = entry.hook {
            if hook.processGeneration == nil {
                hook.processGeneration = generation
                entry.hook = hook
            } else if hook.processGeneration != generation {
                entry.hook = nil
            }
        }
        entry.liveProcessGeneration = generation
        entry.exitedProcessGeneration = nil
        entry.hasUnidentifiedProcessExit = false
        setEntry(entry, key: key, panelId: panelId)
        return true
    }

    /// Invalidates only lifecycle evidence owned by the matching generation.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The owning panel.
    ///   - generation: The exact generation observed exiting.
    /// - Returns: `true` when matching evidence was invalidated.
    @discardableResult
    public mutating func recordProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentProcessGeneration
    ) -> Bool {
        guard var entry = entriesByPanelId[panelId]?[key],
              entry.liveProcessGeneration == generation
                || entry.feedAttentionTokens.contains(where: {
                    $0.processGeneration == generation
                }) else {
            return false
        }
        if entry.liveProcessGeneration == generation {
            entry.liveProcessGeneration = nil
        }
        entry.exitedProcessGeneration = generation
        entry.hasUnidentifiedProcessExit = false
        entry.hook = nil
        entry.suppressesLifecycleUntilNextHook = false
        entry.feedAttentionTokens = Set(
            entry.feedAttentionTokens.filter {
                $0.processGeneration != nil
                    && $0.processGeneration != generation
            }
        )
        setEntry(entry, key: key, panelId: panelId)
        return true
    }

    /// Records a conservative built-in process exit without a readable generation.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The owning panel.
    ///   - isBuiltIn: Whether the key belongs to a built-in integration.
    /// - Returns: `true` when a new tombstone was recorded.
    @discardableResult
    public mutating func recordUnidentifiedProcessExit(
        key: String,
        panelId: UUID,
        isBuiltIn: Bool
    ) -> Bool {
        var entry = entriesByPanelId[panelId]?[key]
            ?? AgentLifecycleEntry()
        entry.isBuiltIn = entry.isBuiltIn || isBuiltIn
        guard entry.isBuiltIn, entry.liveProcessGeneration == nil else {
            return false
        }
        let alreadyRecorded = entry.hasUnidentifiedProcessExit
            && entry.hook == nil
            && entry.feedAttentionTokens.isEmpty
        guard !alreadyRecorded else { return false }
        entry.hasUnidentifiedProcessExit = true
        entry.hook = nil
        entry.suppressesLifecycleUntilNextHook = false
        entry.feedAttentionTokens.removeAll()
        setEntry(entry, key: key, panelId: panelId)
        return true
    }

    /// Removes every kind of evidence for one key.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The owning panel.
    /// - Returns: `true` when evidence existed.
    @discardableResult
    public mutating func removeKey(key: String, panelId: UUID) -> Bool {
        guard entriesByPanelId[panelId]?[key] != nil else {
            return false
        }
        entriesByPanelId[panelId]?.removeValue(forKey: key)
        if entriesByPanelId[panelId]?.isEmpty == true {
            entriesByPanelId.removeValue(forKey: panelId)
        }
        publishResolvedState(for: panelId)
        return true
    }

    /// Removes only the latest hook observation for one key.
    ///
    /// - Parameters:
    ///   - key: The sidebar lifecycle key.
    ///   - panelId: The owning panel.
    /// - Returns: `true` when a hook observation was removed.
    @discardableResult
    public mutating func removeHook(key: String, panelId: UUID) -> Bool {
        guard var entry = entriesByPanelId[panelId]?[key],
              entry.hook != nil else {
            return false
        }
        entry.hook = nil
        entry.suppressesLifecycleUntilNextHook =
            entry.liveProcessGeneration != nil
        setEntry(entry, key: key, panelId: panelId)
        return true
    }

    /// Removes all evidence for one panel.
    ///
    /// - Parameter panelId: The panel being retired.
    /// - Returns: `true` when evidence existed.
    @discardableResult
    public mutating func removePanel(_ panelId: UUID) -> Bool {
        guard entriesByPanelId.removeValue(forKey: panelId) != nil else {
            return false
        }
        resolvedStatesByPanelId.removeValue(forKey: panelId)
        return true
    }

    /// Removes all retained evidence and resolved state.
    public mutating func removeAll() {
        entriesByPanelId.removeAll()
        resolvedStatesByPanelId.removeAll()
    }

    /// Returns an independent snapshot for one panel.
    ///
    /// - Parameter panelId: The panel whose evidence should be copied.
    /// - Returns: A state containing only that panel's evidence.
    public func snapshot(for panelId: UUID) -> Self {
        snapshot(for: panelId) { _ in true }
    }

    /// Returns panel-owned evidence that may follow a detached surface.
    ///
    /// Manual workspace-loading keys are excluded because they belong to the
    /// original workspace rather than to the moving terminal panel.
    ///
    /// - Parameter panelId: The panel whose runtime evidence should be copied.
    /// - Returns: A state containing transferable panel evidence.
    public func panelRuntimeSnapshot(for panelId: UUID) -> Self {
        snapshot(for: panelId) {
            !AgentLifecycleStatusKey(rawValue: $0).isManual
        }
    }

    /// Replaces one panel's evidence with a previously captured snapshot.
    ///
    /// - Parameters:
    ///   - panelId: The panel whose evidence should be replaced.
    ///   - snapshot: A snapshot produced for the same panel identifier.
    public mutating func replacePanel(
        _ panelId: UUID,
        with snapshot: Self
    ) {
        entriesByPanelId.removeValue(forKey: panelId)
        if let entries = snapshot.entriesByPanelId[panelId] {
            entriesByPanelId[panelId] = entries
        }
        publishResolvedState(for: panelId)
    }

    private func snapshot(
        for panelId: UUID,
        keeping shouldKeep: (String) -> Bool
    ) -> Self {
        var snapshot = Self()
        guard let entries = entriesByPanelId[panelId] else {
            return snapshot
        }
        let keptEntries = entries.filter { shouldKeep($0.key) }
        guard !keptEntries.isEmpty else { return snapshot }
        snapshot.entriesByPanelId[panelId] = keptEntries
        snapshot.publishResolvedState(for: panelId)
        return snapshot
    }

    private mutating func setEntry(
        _ entry: AgentLifecycleEntry,
        key: String,
        panelId: UUID
    ) {
        if entry.canBeRemoved {
            entriesByPanelId[panelId]?.removeValue(forKey: key)
        } else {
            entriesByPanelId[panelId, default: [:]][key] = entry
        }
        if entriesByPanelId[panelId]?.isEmpty == true {
            entriesByPanelId.removeValue(forKey: panelId)
        }
        publishResolvedState(for: panelId)
    }

    private mutating func publishResolvedState(for panelId: UUID) {
        guard let entries = entriesByPanelId[panelId] else {
            resolvedStatesByPanelId.removeValue(forKey: panelId)
            return
        }
        var resolved: [String: AgentLifecycleState] = [:]
        for (key, entry) in entries {
            guard let resolution = entry.resolution else { continue }
            // Confidence orders evidence for one lifecycle key. It must not
            // hide a different key (for example the Feed attention overlay)
            // on the same panel; the workspace-level reducer handles
            // disagreement between independently owned keys.
            resolved[key] = resolution.lifecycle
        }
        if resolved.isEmpty {
            resolvedStatesByPanelId.removeValue(forKey: panelId)
        } else {
            resolvedStatesByPanelId[panelId] = resolved
        }
    }

    private func admit(
        processGeneration: AgentProcessGeneration?,
        into entry: inout AgentLifecycleEntry
    ) -> Bool {
        if let processGeneration {
            if let liveProcessGeneration = entry.liveProcessGeneration,
               liveProcessGeneration != processGeneration {
                return false
            }
            if let exitedProcessGeneration = entry.exitedProcessGeneration,
               exitedProcessGeneration >= processGeneration {
                return false
            }
            entry.exitedProcessGeneration = nil
            entry.hasUnidentifiedProcessExit = false
        }
        if entry.isBuiltIn,
           entry.liveProcessGeneration == nil,
           entry.hasProcessExitTombstone,
           processGeneration == nil {
            return false
        }
        if !entry.isBuiltIn, entry.liveProcessGeneration == nil {
            entry.exitedProcessGeneration = nil
        }
        return true
    }
}
