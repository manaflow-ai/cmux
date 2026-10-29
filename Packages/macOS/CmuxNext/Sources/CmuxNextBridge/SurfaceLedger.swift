/// Who presents each content surface (terminal or browser page), and which
/// surfaces render.
///
/// A surface is keyed by its tab, never by the pane showing it, so moving a
/// tab between panes (drag to a split, another pane, a new column) keeps the
/// same surface: the destination pane presents it and the view is reparented.
/// Exactly one presenter owns a key at a time; the latest `present` wins and
/// the previous owner is told it was displaced, so it must let the view go
/// without pausing or destroying it. `withdraw` from a presenter that no
/// longer owns the key is a no-op. This is what keeps a pane that loses a tab
/// (a stale source pane, a pane whose removal animation ends late) from
/// suspending or evicting the surface its destination now shows.
///
/// A key renders while its owner is visible. A key whose owner is in the
/// keep-alive band (an off-screen strip column within one viewport width,
/// architecture.md 4) is paused but pinned: never evicted, so scrolling back
/// shows it at once. Other keys that stop rendering enter the
/// ``SurfaceRetention`` LRU; an evicted key is destroyed, and if a pane still
/// presents it off screen, that pane is told so it re-presents (and the App
/// re-attaches with a daemon replay) when it comes near the viewport again.
public struct SurfaceLedger<Key: Hashable & Sendable, Owner: Hashable & Sendable>: Sendable {
    /// What the caller must do after a ledger change, in order.
    public struct Effects: Equatable, Sendable {
        /// Owners that lost `key` to another presenter or to eviction. They
        /// must drop the view if they still host it, and never withdraw it.
        public var displaced: [Displacement] = []
        /// Keys whose rendering state changed (true = draw, false = pause).
        public var rendering: [Key: Bool] = [:]
        /// Keys whose surfaces must be destroyed now.
        public var evicted: [Key] = []

        public init() {}

        public var isEmpty: Bool { displaced.isEmpty && rendering.isEmpty && evicted.isEmpty }
    }

    public struct Displacement: Equatable, Sendable {
        public var key: Key
        public var owner: Owner
    }

    private var owners: [Key: Owner] = [:]
    /// `owners` inverted, kept by `setOwner`: a presence change reads one
    /// owner's keys, never a scan of every presented key.
    private var ownedKeys: [Owner: Set<Key>] = [:]
    private var ownerPresence: [Owner: SurfacePresence] = [:]
    private var retention: SurfaceRetention<Key>
    /// Keys the LRU never counts or evicts (browser pages: their memory is
    /// managed by hibernation, not by the terminal warm set).
    private var unretained: Set<Key> = []
    /// Rendering state last reported to the caller.
    private var rendering: Set<Key> = []

    public init(capacity: Int = 8) {
        retention = SurfaceRetention(capacity: capacity)
    }

    // MARK: Queries

    public func owner(of key: Key) -> Owner? { owners[key] }

    public func isRendering(_ key: Key) -> Bool { rendering.contains(key) }

    public func isRetained(_ key: Key) -> Bool { retention.isRetained(key) || owners[key] != nil }

    /// Keys `owner` presents (at most one per pane in practice).
    public func keys(ownedBy owner: Owner) -> [Key] {
        ownedKeys[owner].map(Array.init) ?? []
    }

    public var capacity: Int { retention.capacity }

    // MARK: Changes

    /// Keeps `key` out of the LRU (true) or lets it count again (false).
    public mutating func setRetained(_ key: Key, _ retained: Bool) {
        if retained {
            unretained.remove(key)
        } else if unretained.insert(key).inserted {
            retention.remove(key)
        }
    }

    /// Resizes the warm set (memory budget or pressure). Returns the keys
    /// evicted by a smaller capacity.
    public mutating func setCapacity(_ capacity: Int) -> Effects {
        var effects = Effects()
        for evicted in retention.setCapacity(capacity) { evict(evicted, into: &effects) }
        return effects
    }

    /// `owner` shows `key`. Takes it from any previous owner.
    public mutating func present(_ key: Key, by owner: Owner, ownerVisible visible: Bool) -> Effects {
        present(key, by: owner, presence: visible ? .visible : .hidden)
    }

    /// `owner` shows `key` at `presence`. Takes it from any previous owner.
    public mutating func present(_ key: Key, by owner: Owner, presence: SurfacePresence) -> Effects {
        var effects = setPresence(presence, owner: owner)
        if let previous = owners[key], previous != owner {
            effects.displaced.append(Displacement(key: key, owner: previous))
            forgetOwnerIfIdle(previous, except: key)
        }
        setOwner(owner, of: key)
        update(key, into: &effects)
        return effects
    }

    /// `owner` stopped showing `key`. Ignored unless `owner` owns it.
    public mutating func withdraw(_ key: Key, by owner: Owner) -> Effects {
        var effects = Effects()
        guard owners[key] == owner else { return effects }
        setOwner(nil, of: key)
        update(key, into: &effects)
        forgetOwnerIfIdle(owner, except: nil)
        return effects
    }

    /// `owner` scrolled on or off screen (or its screen switched).
    public mutating func setVisible(_ visible: Bool, owner: Owner) -> Effects {
        setPresence(visible ? .visible : .hidden, owner: owner)
    }

    /// `owner` scrolled on screen, into the keep-alive band, or away.
    public mutating func setPresence(_ presence: SurfacePresence, owner: Owner) -> Effects {
        var effects = Effects()
        guard ownerPresence[owner] != presence else { return effects }
        ownerPresence[owner] = presence
        for key in keys(ownedBy: owner) { update(key, into: &effects) }
        return effects
    }

    /// `owner` went away (pane torn down): withdraws everything it presents.
    public mutating func removeOwner(_ owner: Owner) -> Effects {
        var effects = Effects()
        for key in keys(ownedBy: owner) {
            setOwner(nil, of: key)
            update(key, into: &effects)
        }
        ownerPresence[owner] = nil
        return effects
    }

    /// Destroys `key`'s surface now if no pane presents it (its workspace hibernated,
    /// plans/cmux-next/workspace-hibernation-DESIGN.md), instead of when the LRU reaches it. A key a
    /// pane still presents, one outside the LRU, or one not warm is left alone (empty effects).
    public mutating func evictHidden(_ key: Key) -> Effects {
        var effects = Effects()
        guard owners[key] == nil, !unretained.contains(key), retention.isRetained(key) else { return effects }
        retention.remove(key)
        evict(key, into: &effects)
        return effects
    }

    /// The tab closed or its surface was replaced: forget it entirely.
    /// Returns the owner that presented it, if any.
    @discardableResult
    public mutating func remove(_ key: Key) -> Owner? {
        retention.remove(key)
        unretained.remove(key)
        rendering.remove(key)
        guard let owner = owners[key] else { return nil }
        setOwner(nil, of: key)
        forgetOwnerIfIdle(owner, except: nil)
        return owner
    }

    // MARK: Internals

    private func presence(of key: Key) -> SurfacePresence {
        owners[key].flatMap { ownerPresence[$0] } ?? .hidden
    }

    private mutating func update(_ key: Key, into effects: inout Effects) {
        let presence = presence(of: key)
        let render = presence == .visible
        if render != rendering.contains(key) {
            if render { rendering.insert(key) } else { rendering.remove(key) }
            effects.rendering[key] = render
        }
        guard !unretained.contains(key) else { return }
        for evicted in retention.setVisible(key, presence != .hidden) { evict(evicted, into: &effects) }
    }

    private mutating func evict(_ key: Key, into effects: inout Effects) {
        rendering.remove(key)
        effects.rendering[key] = nil
        effects.evicted.append(key)
        if let owner = owners[key] {
            setOwner(nil, of: key)
            effects.displaced.append(Displacement(key: key, owner: owner))
        }
    }

    private mutating func forgetOwnerIfIdle(_ owner: Owner, except key: Key?) {
        let keys = ownedKeys[owner] ?? []
        guard keys.isEmpty || (keys.count == 1 && key.map(keys.contains) == true) else { return }
        ownerPresence[owner] = nil
    }

    /// The one writer of `owners`, so `ownedKeys` stays its inverse.
    private mutating func setOwner(_ owner: Owner?, of key: Key) {
        if let previous = owners[key] {
            ownedKeys[previous]?.remove(key)
            if ownedKeys[previous]?.isEmpty == true { ownedKeys[previous] = nil }
        }
        owners[key] = owner
        if let owner { ownedKeys[owner, default: []].insert(key) }
    }
}

/// How near a presenter is to the viewport.
public enum SurfacePresence: Hashable, Sendable {
    /// On screen: render.
    case visible
    /// Off screen within the keep-alive band: keep the surface, paused.
    case keepAlive
    /// Away: pause; the surface may be evicted by the LRU.
    case hidden
}
