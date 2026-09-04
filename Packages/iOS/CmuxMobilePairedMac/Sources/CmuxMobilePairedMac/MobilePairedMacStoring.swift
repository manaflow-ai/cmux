public import CMUXMobileCore
public import Foundation

/// Persistence seam for paired Macs, conformed by ``MobilePairedMacStore``.
///
/// Higher layers depend on `any MobilePairedMacStoring` and the concrete actor
/// is constructed once at the app composition root, so the store can be replaced
/// with an in-memory double in tests and previews without a singleton factory.
public protocol MobilePairedMacStoring: Sendable {
    /// Insert or update a paired Mac and its routes.
    /// - Parameters:
    ///   - macDeviceID: Stable identifier of the Mac.
    ///   - displayName: Optional human-readable Mac name.
    ///   - routes: Attach routes advertised by the Mac.
    ///   - instanceTag: Authenticated Mac app-instance tag, or `nil` when the
    ///     host is legacy/unknown and route authority must remain conservative.
    ///   - markActive: When `true`, makes this the active pairing for its scope.
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team this pairing belongs to; stamped on the row so the
    ///     local list can be scoped per team. `nil` leaves the team unset (anonymous
    ///     / pre-team pairing).
    ///   - now: Timestamp used for `lastSeenAt` (and `createdAt` on first insert).
    func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws

    /// Atomically insert a missing row or replace a strictly older row. Used by
    /// backup restore so an authenticated live write cannot land between a
    /// freshness check and a stale restore upsert.
    @discardableResult
    func upsertIfNewer(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool

    /// Atomically write host-owned display and route data only while the scoped
    /// row satisfies `condition`. `markActive: nil` preserves the current
    /// selection; a non-nil value applies the requested selection state.
    @discardableResult
    func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool

    /// Load all paired Macs, optionally scoped to a Stack user and team.
    /// - Parameters:
    ///   - stackUserID: When set, returns only Macs owned by that user.
    ///   - teamID: When set, returns only Macs in that team (plus team-less legacy
    ///     rows, so an upgrade never hides existing hosts). `nil` = every team.
    /// - Returns: Paired Macs ordered by `lastSeenAt` descending.
    func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac]

    /// Return the active paired Mac for a scope, if any.
    /// - Parameters:
    ///   - stackUserID: When set, scopes the lookup to that user.
    ///   - teamID: When set, scopes the lookup to that team (plus team-less rows).
    func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac?

    /// Mark the given Mac as the single active pairing in one owner scope.
    /// - Parameters:
    ///   - macDeviceID: Mac to activate.
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team this activation belongs to, if any.
    func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws

    /// Mark one exact tagged Mac app instance active.
    func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws

    /// Clear the active pairing for one visible owner scope.
    /// - Parameters:
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team whose visible rows should be cleared. When set,
    ///     team-less legacy rows are cleared too because they are visible in that
    ///     team scope.
    func clearActive(stackUserID: String?, teamID: String?) async throws

    /// Set the user's per-Mac customizations (synced per user). Leaves the
    /// Mac-reported name, routes, and active flag untouched, and bumps
    /// `lastSeenAt` so the change is the freshest write for LWW sync.
    /// - Parameters:
    ///   - macDeviceID: Mac to customize.
    ///   - customName: Name override, or `nil` to clear it.
    ///   - customColor: Color override (`"palette:<n>"` / `"#RRGGBB"`), or `nil`.
    ///   - customIcon: Icon override (SF Symbol name or emoji), or `nil`.
    ///   - now: Timestamp for `lastSeenAt`.
    func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws

    /// Set customizations on one exact tagged Mac app instance.
    func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws

    /// Remove a single paired Mac in one owner scope.
    /// - Parameters:
    ///   - macDeviceID: Mac to forget.
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team this pairing belongs to, if any.
    func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws

    /// Remove one exact tagged Mac app instance.
    func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws

    /// Remove one exact tagged Mac app instance in the EXACT owner scope the
    /// caller captured, without re-resolving a nil `teamID` to the currently
    /// selected team.
    ///
    /// The forget path captures its scope before an async network revoke, then
    /// deletes the stored row. If the user switches teams during that await, a
    /// nil (team-less) captured `teamID` must still delete the team-less row it
    /// was captured against, not the freshly selected team's rows. Decorators
    /// that substitute a nil `teamID` with the live team selection override this
    /// to bypass that substitution and honor the captured scope verbatim.
    func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws

    /// Every stored instance of one physical device owned by one account,
    /// across ALL team scopes and instance tags.
    ///
    /// The forget flow's wildcard revoke kills the device's bindings for the
    /// whole account, so its local cleanup must be able to see the device's
    /// rows in OTHER teams than the one currently displayed — the ordinary
    /// `loadAll(stackUserID:teamID:)` is deliberately team-scoped and cannot.
    /// Team-substituting decorators override this to bypass their live-team
    /// resolution and forward verbatim.
    func loadAllInstances(
        macDeviceID: String,
        stackUserID: String?
    ) async throws -> [MobilePairedMac]

    /// Remove several exact row scopes as one batch, so stores with per-delete
    /// side effects (the backup-mirroring decorator's tombstone flush) can
    /// coalesce them instead of paying one network round-trip per row.
    func removeExactScopes(_ scopes: [MobilePairedMacExactScope]) async throws

    /// Remove all paired Macs.
    func removeAll() async throws

    /// Persist THIS device's connection-method choice for one tagged Mac
    /// (an opaque raw value owned by the shell; `nil` clears the choice back
    /// to the app default). Device-local: the value never syncs, never backs
    /// up, and must not bump LWW freshness.
    func setConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        rawValue: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws

    /// Persist THIS device's Direct-method dial candidates for one tagged Mac
    /// (a JSON payload owned by the shell; `nil` clears the list). Device-local
    /// like the connection method.
    func setDirectAddresses(
        macDeviceID: String,
        instanceTag: String?,
        rawJSON: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws

    /// Record device-local authorization for Tailscale routes the user entered
    /// as a pairing code from their Mac.
    ///
    /// The authorization event is the user reading the compatibility code off
    /// the Mac's pairing window; only the exact scanned destinations become
    /// dialable, only on this device (grants never sync or back up). Rows for
    /// non-Tailscale or non-host/port routes are ignored. The scoped paired-Mac
    /// row must already exist.
    func authorizeUserTailscaleRoutes(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        routes: [CmxAttachRoute]
    ) async throws
}

extension MobilePairedMacStoring {
    /// Compatibility no-op for stores that predate per-Computer Direct
    /// addresses (test fixtures); the SQLite store and decorators override.
    public func setDirectAddresses(
        macDeviceID: String,
        instanceTag: String?,
        rawJSON: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {}

    /// Compatibility no-op for stores that predate per-Computer connection
    /// methods (test fixtures); the SQLite store and decorators override.
    public func setConnectionMethod(
        macDeviceID: String,
        instanceTag: String?,
        rawValue: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {}

    /// Compatibility fallback for stores that predate tagged row identity.
    /// Tagged mutations fail closed because a device-only implementation
    /// cannot prove which sibling build it would change.
    public func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).instanceTag == nil else { return }
        try await setActive(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Compatibility fallback for stores that predate tagged row identity.
    /// Tagged mutations fail closed because a device-only implementation
    /// cannot prove which sibling build it would change.
    public func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws {
        guard CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).instanceTag == nil else { return }
        try await setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    /// Compatibility fallback for stores that predate tagged row identity.
    /// Tagged mutations fail closed because a device-only implementation
    /// cannot prove which sibling build it would change.
    public func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        guard CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).instanceTag == nil else { return }
        try await remove(
            macDeviceID: macDeviceID,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Default: the base SQLite store never re-resolves a nil `teamID`, so its
    /// exact-scope removal is the tagged remove unchanged. Decorators whose
    /// general `remove` widens the delete override this: team-substituting
    /// decorators (``TeamScopedPairedMacStore``, ``BackingUpPairedMacStore``)
    /// re-resolve a nil team to the live one, and the build-scope decorator
    /// additionally drops its team-less fallback row. Each overrides
    /// `removeExactScope` to delete exactly the captured scope and nothing else.
    public func removeExactScope(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?
    ) async throws {
        try await remove(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Default cross-team instance enumeration: a nil `teamID` on the BASE
    /// store's `loadAll` returns every team's rows, so filtering by the
    /// canonical device id yields all of the device's instances. Correct for
    /// the base SQLite store and simple in-memory stores ONLY — any decorator
    /// that substitutes a nil team with the live selection, or that re-scopes
    /// team ids, must override this to keep the enumeration genuinely
    /// cross-team.
    public func loadAllInstances(
        macDeviceID: String,
        stackUserID: String?
    ) async throws -> [MobilePairedMac] {
        let canonical = cmxCanonicalDeviceID(macDeviceID)
        return try await loadAll(stackUserID: stackUserID, teamID: nil)
            .filter { cmxCanonicalDeviceID($0.macDeviceID) == canonical }
    }

    /// Default batch removal: each scope through this store's own
    /// `removeExactScope`, in order. Stores whose per-delete side effects are
    /// expensive (the backup-mirroring decorator's tombstone flush) override
    /// this to coalesce.
    public func removeExactScopes(_ scopes: [MobilePairedMacExactScope]) async throws {
        for scope in scopes {
            try await removeExactScope(
                macDeviceID: scope.macDeviceID,
                instanceTag: scope.instanceTag,
                stackUserID: scope.stackUserID,
                teamID: scope.teamID
            )
        }
    }

    /// In-memory/test fallback. Production SQLite and scope decorators override
    /// this with one atomic storage operation.
    @discardableResult
    public func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        let matches = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter {
                cmxCanonicalDeviceID($0.macDeviceID) == cmxCanonicalDeviceID(macDeviceID)
            }
        let existing: MobilePairedMac?
        switch condition {
        case .matchingInstanceTag(let tag):
            let expectedID = CmxMacAppInstanceIdentity(
                macDeviceID: macDeviceID,
                instanceTag: tag
            ).id
            existing = matches.first {
                CmxMacAppInstanceIdentity(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag
                ).id == expectedID
            }
            guard existing != nil else { return false }
        case .unclaimed:
            guard !matches.contains(where: { $0.instanceTag != nil }) else { return false }
            existing = matches.first { $0.instanceTag == nil }
        }
        try await upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: existing?.instanceTag,
            markActive: markActive ?? existing?.isActive ?? false,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
        return true
    }

    /// In-memory/test fallback. Production SQLite and scope decorators override
    /// this requirement with one atomic storage operation.
    @discardableResult
    public func upsertIfNewer(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        let expectedIdentity = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        let matches = try await loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter {
                cmxCanonicalDeviceID($0.macDeviceID) == expectedIdentity.macDeviceID
            }
        if expectedIdentity.instanceTag == nil,
           matches.contains(where: { $0.instanceTag != nil }) {
            return false
        }
        let existing = matches.first {
                CmxMacAppInstanceIdentity(
                    macDeviceID: $0.macDeviceID,
                    instanceTag: $0.instanceTag
                ).id == expectedIdentity.id
            }
        if let existing, existing.lastSeenAt >= now { return false }
        try await upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: expectedIdentity.instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
        try await setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: expectedIdentity.instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
        return true
    }

    /// Insert or update a paired Mac with an explicit timestamp but no team scope
    /// (`teamID: nil`). Keeps existing call sites compiling; the team-aware caller
    /// (``BackingUpPairedMacStore``) injects the team via the full requirement.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String? = nil,
        markActive: Bool,
        stackUserID: String?,
        now: Date
    ) async throws {
        try await upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: nil,
            now: now
        )
    }

    /// Insert or update a paired Mac, timestamping with the current `Date` and no
    /// team scope.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String? = nil,
        markActive: Bool,
        stackUserID: String?
    ) async throws {
        try await upsert(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: nil,
            now: Date()
        )
    }

    /// Load all paired Macs for a Stack user across every team.
    public func loadAll(stackUserID: String?) async throws -> [MobilePairedMac] {
        try await loadAll(stackUserID: stackUserID, teamID: nil)
    }

    /// Load all paired Macs across every Stack user and team scope.
    public func loadAll() async throws -> [MobilePairedMac] {
        try await loadAll(stackUserID: nil, teamID: nil)
    }

    /// Return the active paired Mac for a Stack user across every team, if any.
    public func activeMac(stackUserID: String?) async throws -> MobilePairedMac? {
        try await activeMac(stackUserID: stackUserID, teamID: nil)
    }

    /// Return the active paired Mac across every Stack user and team scope, if any.
    public func activeMac() async throws -> MobilePairedMac? {
        try await activeMac(stackUserID: nil, teamID: nil)
    }

    /// Mark the given Mac active without an explicit owner scope. Implementations
    /// may use this only for legacy/unscoped rows; team-aware callers should pass
    /// the captured scope through the full requirement.
    public func setActive(macDeviceID: String) async throws {
        try await setActive(macDeviceID: macDeviceID, stackUserID: nil, teamID: nil)
    }

    /// Persist customizations without an explicit owner scope. Team-aware callers
    /// should pass the captured scope through the full requirement.
    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        now: Date
    ) async throws {
        try await setCustomization(
            macDeviceID: macDeviceID,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: nil,
            teamID: nil,
            now: now
        )
    }

    /// Remove a Mac without an explicit owner scope. Team-aware callers should
    /// pass the captured scope through the full requirement.
    public func remove(macDeviceID: String) async throws {
        try await remove(macDeviceID: macDeviceID, stackUserID: nil, teamID: nil)
    }
}
