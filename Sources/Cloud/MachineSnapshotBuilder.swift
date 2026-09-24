import Foundation

enum MachineSnapshotBuilder {
    /// The fleet plus machines the catalog discovered before the list endpoint
    /// returned them (or returned them under another name): the complete set of
    /// machine rows the tree shows, in fleet order with discoveries appended.
    static func includingCatalogMachines(_ machines: [MachineSnapshot], catalog: SurfaceCatalogSnapshot) -> [MachineSnapshot] {
        var seen = Set(machines.map(\.id))
        return machines + catalog.machines.compactMap { info in
            guard let id = info.id.cloudMachineID, seen.insert(id).inserted else { return nil }
            return MachineSnapshot(
                id: id,
                provider: "",
                image: info.image ?? "",
                isDesktop: info.hasDesktop,
                activity: activity(fromStatus: info.status),
                createdAt: nil,
                label: info.name == id ? nil : info.name,
                privateAddress: info.privateAddress
            )
        }
    }

    static func snapshot(
        from summary: VMSummary,
        freeAccessWindowDays: Int = 0,
        now: Date = Date(),
        previousStats: VMStats? = nil
    ) -> MachineSnapshot {
        let createdAt = summary.createdAt > 0
            ? Date(timeIntervalSince1970: TimeInterval(summary.createdAt) / 1000)
            : nil
        // The backend's expiry wins when it sends one; the local window math is
        // the fallback for older control planes.
        let freeAccess = summary.freeAccessExpiresAt.map { expiresAt in
            freeAccessState(expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000), now: now)
        } ?? freeAccessState(createdAt: createdAt, windowDays: freeAccessWindowDays, now: now)
        return MachineSnapshot(
            id: summary.id,
            provider: summary.provider,
            image: summary.image,
            isDesktop: summary.resolvedKind.hasDesktop,
            capabilities: summary.capabilities,
            activity: activity(fromStatus: summary.status),
            createdAt: createdAt,
            label: summary.displayName,
            slug: summary.slug,
            freeAccess: freeAccess,
            stats: summary.capabilities.stats ? previousStats : nil,
            privateAddress: summary.preferredPrivateAddress
        )
    }

    /// Row state from a known expiry instant.
    static func freeAccessState(expiresAt: Date, now: Date = Date()) -> MachineSnapshot.FreeAccessState {
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        return .active(daysLeft: Int((remaining / 86_400).rounded(.up)))
    }

    /// "6d 23h" while more than a day remains, "5h 12m" under a day, "1m" at
    /// the floor. Whole units, truncated: a countdown must never overstate.
    static func freeAccessCountdown(remaining: TimeInterval) -> String {
        let total = max(Int(remaining), 60)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return String(
                format: String(localized: "machines.freeAccess.countdown.daysHours", defaultValue: "%1$dd %2$dh"),
                days, hours
            )
        }
        if hours > 0 {
            return String(
                format: String(localized: "machines.freeAccess.countdown.hoursMinutes", defaultValue: "%1$dh %2$dm"),
                hours, minutes
            )
        }
        return String(
            format: String(localized: "machines.freeAccess.countdown.minutes", defaultValue: "%dm"),
            max(minutes, 1)
        )
    }

    /// Header banner for the fleet's earliest expiry. Paid plans never see one.
    static func freeAccessBanner(
        expiresAt: Date?,
        isPaidPlan: Bool,
        now: Date = Date()
    ) -> MachinePlanSnapshot.FreeAccessBanner {
        guard !isPaidPlan, let expiresAt else { return .none }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        let countdown = freeAccessCountdown(remaining: remaining)
        return remaining < 86_400 ? .expiresToday(countdown: countdown) : .expiresIn(countdown: countdown)
    }

    /// The fleet's earliest free-access expiry: the server's figure when it
    /// sends one, else the earliest `createdAt + window` across the machines.
    static func earliestFreeAccessExpiry(
        limits: VMPlanLimits,
        machines: [MachineSnapshot]
    ) -> Date? {
        if let serverMs = limits.freeAccessExpiresAt {
            return Date(timeIntervalSince1970: TimeInterval(serverMs) / 1000)
        }
        guard limits.freeAccessWindowDays > 0 else { return nil }
        return machines
            .compactMap { $0.createdAt?.addingTimeInterval(TimeInterval(limits.freeAccessWindowDays) * 86_400) }
            .min()
    }

    /// Mirrors the backend's window math (created + windowDays vs now); the
    /// backend stays the enforcement point, this only drives the row UI.
    static func freeAccessState(
        createdAt: Date?,
        windowDays: Int,
        now: Date = Date()
    ) -> MachineSnapshot.FreeAccessState {
        guard windowDays > 0, let createdAt else { return .unrestricted }
        let remaining = createdAt.addingTimeInterval(TimeInterval(windowDays) * 86_400).timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        return .active(daysLeft: Int((remaining / 86_400).rounded(.up)))
    }

    /// The next instant at which a machine's free-access presentation changes:
    /// each day-boundary where the "N days left" label decrements, and finally
    /// the expiry itself. Nil once expired (or when no window applies) — there
    /// is nothing left to wait for. Expiry is a *known future timestamp*, so
    /// the panel arms a one-shot timer at exactly this instant instead of
    /// discovering the transition on a poll sweep.
    static func nextFreeAccessTransition(
        createdAt: Date?,
        windowDays: Int,
        now: Date = Date()
    ) -> Date? {
        guard windowDays > 0, let createdAt else { return nil }
        let expiry = createdAt.addingTimeInterval(TimeInterval(windowDays) * 86_400)
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let daysLeft = Int((remaining / 86_400).rounded(.up))
        // The label decrements when remaining crosses (daysLeft - 1) whole days;
        // for the final day that crossing IS the expiry.
        return expiry.addingTimeInterval(-TimeInterval(daysLeft - 1) * 86_400)
    }

    /// Stamps each snapshot with its usage readout, keyed by the machine id
    /// (`GET /api/vm` `id`, which the usage payload echoes as `vmId`). Machines
    /// the payload does not name lose any earlier readout so a machine that
    /// dropped out of the window never keeps a stale number.
    static func applyingUsage(
        to snapshots: [MachineSnapshot],
        usage: [String: MachineUsageSnapshot]
    ) -> [MachineSnapshot] {
        snapshots.map { snapshot in
            var next = snapshot
            next.usage = usage[snapshot.id]
            return next
        }
    }

    /// Recomputes only the free-access facet of existing snapshots against a
    /// fresh clock — no network, stats and identity preserved.
    static func applyingFreeAccess(
        to snapshots: [MachineSnapshot],
        windowDays: Int,
        now: Date = Date()
    ) -> [MachineSnapshot] {
        snapshots.map { snapshot in
            var next = snapshot
            next.freeAccess = freeAccessState(createdAt: snapshot.createdAt, windowDays: windowDays, now: now)
            return next
        }
    }

    static func activity(fromStatus status: String) -> MachineSnapshot.Activity {
        switch status.lowercased() {
        case "running", "ready", "standby", "paused":
            return .ready
        case "creating", "starting", "pending", "resuming":
            return .pending
        default:
            return .attention(status)
        }
    }

    static func planSnapshot(
        activeCount: Int,
        limits: VMPlanLimits?,
        machines: [MachineSnapshot] = [],
        now: Date = Date()
    ) -> MachinePlanSnapshot? {
        guard let limits else { return nil }
        let isPaidPlan = MachinePlanSnapshot.isPaidPlanID(limits.planId)
        let expiresAt = isPaidPlan ? nil : earliestFreeAccessExpiry(limits: limits, machines: machines)
        return MachinePlanSnapshot(
            activeCount: activeCount,
            maxActiveVms: limits.maxActiveVms,
            planId: limits.planId,
            freeAccessWindowDays: limits.freeAccessWindowDays,
            freeAccessExpiresAt: expiresAt,
            freeAccessBanner: freeAccessBanner(expiresAt: expiresAt, isPaidPlan: isPaidPlan, now: now)
        )
    }
}
