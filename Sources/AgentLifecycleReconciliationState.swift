import Foundation

struct AgentFeedAttentionToken: Hashable, Sendable {
    let id: UUID
    let processGeneration: AgentPIDProcessIdentity?
}

/// Reconciles hook, Feed-attention, and process-generation evidence into the
/// legacy per-panel lifecycle snapshot consumed by the sidebar and hibernation.
struct AgentLifecycleReconciliationState {
    private enum Confidence: Int, Comparable {
        case unboundHook
        case liveProcess
        case feedAttention

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct Resolution {
        let lifecycle: AgentHibernationLifecycleState
        let confidence: Confidence
    }

    private struct HookObservation: Equatable {
        var lifecycle: AgentHibernationLifecycleState
        var processGeneration: AgentPIDProcessIdentity?
    }

    private struct Entry: Equatable {
        var hook: HookObservation?
        var feedAttentionTokens: Set<AgentFeedAttentionToken> = []
        var liveProcessGeneration: AgentPIDProcessIdentity?
        var exitedProcessGeneration: AgentPIDProcessIdentity?
        var hasUnidentifiedProcessExit = false
        var suppressesLifecycleUntilNextHook = false
        var isBuiltIn = false

        var hasProcessExitTombstone: Bool {
            exitedProcessGeneration != nil || hasUnidentifiedProcessExit
        }

        var resolution: Resolution? {
            if !feedAttentionTokens.isEmpty {
                return Resolution(
                    lifecycle: .needsInput,
                    confidence: .feedAttention
                )
            }
            if suppressesLifecycleUntilNextHook {
                return nil
            }
            if let liveProcessGeneration {
                guard let hook else {
                    return Resolution(
                        lifecycle: .unknown,
                        confidence: .liveProcess
                    )
                }
                guard hook.processGeneration == liveProcessGeneration else {
                    return Resolution(
                        lifecycle: .unknown,
                        confidence: .liveProcess
                    )
                }
                return Resolution(
                    lifecycle: hook.lifecycle,
                    confidence: .liveProcess
                )
            }
            if hasProcessExitTombstone, isBuiltIn {
                return nil
            }
            return hook.map {
                Resolution(
                    lifecycle: $0.lifecycle,
                    confidence: .unboundHook
                )
            }
        }

        var canBeRemoved: Bool {
            hook == nil
                && feedAttentionTokens.isEmpty
                && liveProcessGeneration == nil
                && exitedProcessGeneration == nil
                && !hasUnidentifiedProcessExit
        }
    }

    private var entriesByPanelId: [UUID: [String: Entry]] = [:]
    private(set) var resolvedStatesByPanelId:
        [UUID: [String: AgentHibernationLifecycleState]] = [:]
    var hasEvidence: Bool { !entriesByPanelId.isEmpty }
    var panelIdsWithEvidence: Set<UUID> { Set(entriesByPanelId.keys) }

    /// Records a hook observation and binds it to the current live process
    /// generation when one exists. A dead-generation tombstone rejects
    /// unbound delayed hooks until a new PID generation is recorded.
    @discardableResult
    mutating func setHookLifecycle(
        key: String,
        panelId: UUID,
        lifecycle: AgentHibernationLifecycleState,
        isBuiltIn: Bool,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> Bool {
        var entry = entriesByPanelId[panelId]?[key] ?? Entry()
        entry.isBuiltIn = entry.isBuiltIn || isBuiltIn
        if let processGeneration {
            // Hook generations have an ordering relationship: an older queued
            // hook must not replace evidence from a newer turn process. Feed
            // attention tokens are opaque decisions and intentionally do not
            // use this chronological check.
            if entry.liveProcessGeneration == nil,
               let currentGeneration = entry.hook?.processGeneration,
               currentGeneration != processGeneration,
               Self.generationPrecedes(
                   processGeneration,
                   currentGeneration
               ) {
                return false
            }
        }
        guard Self.admit(
            processGeneration: processGeneration,
            into: &entry
        ) else { return false }
        entry.hook = HookObservation(
            lifecycle: lifecycle,
            processGeneration:
                processGeneration ?? entry.liveProcessGeneration
        )
        entry.suppressesLifecycleUntilNextHook = false
        setEntry(entry, key: key, panelId: panelId)
        return true
    }

    /// Starts a Feed-owned needs-input overlay. Hook updates cannot clear this
    /// evidence; only the matching Feed conclusion decrements the count.
    /// Returns the token that must be supplied when this exact decision ends.
    mutating func beginFeedAttention(
        key: String,
        panelId: UUID,
        isBuiltIn: Bool,
        processGeneration: AgentPIDProcessIdentity? = nil
    ) -> AgentFeedAttentionToken? {
        var entry = entriesByPanelId[panelId]?[key] ?? Entry()
        entry.isBuiltIn = entry.isBuiltIn || isBuiltIn
        guard Self.admit(
            processGeneration: processGeneration,
            into: &entry
        ) else { return nil }
        let token = AgentFeedAttentionToken(
            id: UUID(),
            processGeneration:
                processGeneration ?? entry.liveProcessGeneration
        )
        entry.feedAttentionTokens.insert(token)
        setEntry(entry, key: key, panelId: panelId)
        return token
    }

    func hasFeedAttention(key: String, panelId: UUID) -> Bool {
        entriesByPanelId[panelId]?[key]?.feedAttentionTokens.isEmpty == false
    }

    /// Concludes only the matching Feed-owned overlay. A delayed reply from a
    /// dead or replaced generation cannot decrement a newer process's token.
    @discardableResult
    mutating func endFeedAttention(
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

    /// Binds lifecycle evidence to a newly observed process generation.
    mutating func recordProcessGeneration(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity,
        isBuiltIn: Bool
    ) {
        var entry = entriesByPanelId[panelId]?[key] ?? Entry()
        entry.isBuiltIn = entry.isBuiltIn || isBuiltIn
        if entry.liveProcessGeneration != generation {
            entry.suppressesLifecycleUntilNextHook = false
        }
        if let previousGeneration = entry.liveProcessGeneration,
           previousGeneration != generation {
            entry.feedAttentionTokens.removeAll()
        } else {
            entry.feedAttentionTokens = Set(
                entry.feedAttentionTokens.filter {
                    $0.processGeneration == nil
                        || $0.processGeneration == generation
                }
            )
        }
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
    }

    /// Invalidates only the matching process generation. Matching hook and
    /// Feed evidence is removed and a tombstone prevents a queued hook from
    /// resurrecting the dead agent.
    @discardableResult
    mutating func recordProcessExit(
        key: String,
        panelId: UUID,
        generation: AgentPIDProcessIdentity
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

    /// Rejects delayed built-in evidence after a PID was already gone before
    /// its exact start identity could be captured. A later exact generation
    /// clears this conservative tombstone.
    @discardableResult
    mutating func recordUnidentifiedProcessExit(
        key: String,
        panelId: UUID,
        isBuiltIn: Bool
    ) -> Bool {
        var entry = entriesByPanelId[panelId]?[key] ?? Entry()
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

    /// Removes lifecycle evidence when no trustworthy process generation was
    /// available. This preserves legacy cleanup for custom integrations.
    @discardableResult
    mutating func removeKey(key: String, panelId: UUID) -> Bool {
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

    @discardableResult
    mutating func removeHook(key: String, panelId: UUID) -> Bool {
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

    @discardableResult
    mutating func removePanel(_ panelId: UUID) -> Bool {
        guard entriesByPanelId.removeValue(forKey: panelId) != nil else {
            return false
        }
        resolvedStatesByPanelId.removeValue(forKey: panelId)
        return true
    }

    mutating func removeAll() {
        entriesByPanelId.removeAll()
        resolvedStatesByPanelId.removeAll()
    }

    func snapshot(for panelId: UUID) -> Self {
        snapshot(for: panelId) { _ in true }
    }

    /// Returns only panel-owned evidence that may follow a detached surface.
    func panelRuntimeSnapshot(for panelId: UUID) -> Self {
        snapshot(for: panelId) {
            !AgentHibernationLifecycleStatusKeys.isManualKey($0)
        }
    }

    private func snapshot(
        for panelId: UUID,
        keeping shouldKeep: (String) -> Bool
    ) -> Self {
        var snapshot = Self()
        guard let entries = entriesByPanelId[panelId] else {
            return snapshot
        }
        let keptEntries = entries.filter {
            shouldKeep($0.key)
        }
        guard !keptEntries.isEmpty else {
            return snapshot
        }
        snapshot.entriesByPanelId[panelId] = keptEntries
        snapshot.publishResolvedState(for: panelId)
        return snapshot
    }

    mutating func replacePanel(
        _ panelId: UUID,
        with snapshot: Self
    ) {
        entriesByPanelId.removeValue(forKey: panelId)
        if let entries = snapshot.entriesByPanelId[panelId] {
            entriesByPanelId[panelId] = entries
        }
        publishResolvedState(for: panelId)
    }

    private mutating func setEntry(
        _ entry: Entry,
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
        var resolved: [String: AgentHibernationLifecycleState] = [:]
        for (key, entry) in entries
        where AgentHibernationLifecycleStatusKeys.isManualKey(key) {
            if let resolution = entry.resolution {
                resolved[key] = resolution.lifecycle
            }
        }

        let agentResolutions = entries.compactMap {
            key, entry -> (String, Resolution)? in
            guard !AgentHibernationLifecycleStatusKeys.isManualKey(key),
                  let resolution = entry.resolution else {
                return nil
            }
            return (key, resolution)
        }
        if let highestConfidence = agentResolutions
            .map(\.1.confidence)
            .max() {
            // A panel represents one running agent even when stale adapters
            // leave several status keys behind. Lower-confidence keys are
            // ignored as stale evidence; equally authoritative disagreement
            // is published as unknown instead of reviving fixed enum
            // precedence across integrations.
            let authoritative = agentResolutions.filter {
                $0.1.confidence == highestConfidence
            }
            let authoritativeStates = Set(
                authoritative.map(\.1.lifecycle)
            )
            let publishedLifecycle = authoritativeStates.count == 1
                ? authoritativeStates.first ?? .unknown
                : .unknown
            for (key, _) in authoritative {
                resolved[key] = publishedLifecycle
            }
        }
        if resolved.isEmpty {
            resolvedStatesByPanelId.removeValue(forKey: panelId)
        } else {
            resolvedStatesByPanelId[panelId] = resolved
        }
    }

    /// Applies the common process-generation and exit-tombstone admission
    /// policy for hook and Feed evidence.
    private static func admit(
        processGeneration: AgentPIDProcessIdentity?,
        into entry: inout Entry
    ) -> Bool {
        if let processGeneration {
            if let liveProcessGeneration = entry.liveProcessGeneration,
               liveProcessGeneration != processGeneration {
                return false
            }
            if let exitedProcessGeneration =
                entry.exitedProcessGeneration,
               !Self.generationPrecedes(
                   exitedProcessGeneration,
                   processGeneration
               ) {
                return false
            }
            // An exact event can race ahead of PID registration and proves an
            // older tombstone does not describe this process generation.
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

    private static func generationPrecedes(
        _ candidate: AgentPIDProcessIdentity,
        _ reference: AgentPIDProcessIdentity
    ) -> Bool {
        if candidate.startSeconds != reference.startSeconds {
            return candidate.startSeconds < reference.startSeconds
        }
        if candidate.startMicroseconds != reference.startMicroseconds {
            return candidate.startMicroseconds
                < reference.startMicroseconds
        }
        return candidate.pid < reference.pid
    }
}
