public import Foundation
public import CoreGraphics
public import Bonsplit

/// The pure portal-host lease decision logic for a browser panel, lifted out of
/// `BrowserPanel` as a value type.
///
/// A browser panel can be presented through more than one portal host view at a
/// time (split churn, workspace switches, drag handoffs). This machine decides
/// which competing host owns the panel's portal binding by window attachment,
/// visible area, and an explicit replacement lock, exactly mirroring the legacy
/// `claimPortalHost`/`releasePortalHostIfOwned`/
/// `preparePortalHostReplacementForNextDistinctClaim` logic.
///
/// This machine is browser-domain-specific and deliberately distinct from
/// `CmuxTerminalCore.PortalHostLease`: the terminal lease arbitrates by a
/// monotonically increasing `instanceSerial`, while the browser arbitrates by an
/// area-gain ratio plus a same-pane replacement lock and a one-shot
/// "force-distinct" re-arm. The two domains share only the name shape, not the
/// fields or the decision, so they are not unified.
///
/// The machine owns only the transient lease state (the active lease, the locked
/// host, and the pending force-distinct pane). It performs no I/O, posts no
/// notifications, and emits no logs. The host view's identity is an opaque
/// ``ObjectIdentifier`` passed in by the panel; the actual webview/portal
/// mutations and the `#if DEBUG` `cmuxDebugLog` markers stay app-side. The owning
/// panel holds an instance, feeds it `(hostId, paneId, inWindow, bounds)`, adopts
/// the returned ``machine`` state, emits the requested ``DebugEvent`` markers, and
/// returns the boolean claim/release verdict to its caller. Whether the panel is
/// in local inline developer-tools hosting mode (which short-circuits the claim)
/// is gated app-side and passed in as `usesLocalInlineDeveloperToolsHosting`.
public struct BrowserPortalHostLeaseMachine: Sendable, Equatable {
    /// The minimum visible area for a lease to count as usable. A host below this
    /// area (or off-window) cannot block a replacement and is itself replaceable.
    public static let portalHostAreaThreshold: CGFloat = 4

    /// The factor a competing same-pane host's area must exceed the incumbent's by
    /// to win an unforced replacement.
    public static let portalHostReplacementAreaGainRatio: CGFloat = 1.2

    /// One portal host's claim on the panel, mirroring the legacy
    /// `PortalHostLease` struct field-for-field.
    public struct Lease: Sendable, Equatable {
        /// The identity of the host view holding the lease.
        public let hostId: ObjectIdentifier

        /// The pane the host belongs to.
        public let paneId: UUID

        /// Whether the host was window-attached when it took the lease.
        public let inWindow: Bool

        /// The host's visible area when it took the lease.
        public let area: CGFloat

        /// Creates a lease record for one portal host.
        public init(hostId: ObjectIdentifier, paneId: UUID, inWindow: Bool, area: CGFloat) {
            self.hostId = hostId
            self.paneId = paneId
            self.inWindow = inWindow
            self.area = area
        }

        /// Whether this lease is usable (window-attached and above the area floor),
        /// mirroring the legacy `portalHostIsUsable(_:)`.
        public var isUsable: Bool {
            inWindow && area > BrowserPortalHostLeaseMachine.portalHostAreaThreshold
        }
    }

    /// A same-pane replacement lock, mirroring the legacy `PortalHostLock` struct.
    ///
    /// When set and matching the active lease, it blocks an unforced same-pane
    /// replacement until a force-distinct re-arm or a different-pane/unusable
    /// claim clears it.
    public struct Lock: Sendable, Equatable {
        /// The locked host's identity.
        public let hostId: ObjectIdentifier

        /// The locked host's pane.
        public let paneId: UUID

        /// Creates a same-pane replacement lock.
        public init(hostId: ObjectIdentifier, paneId: UUID) {
            self.hostId = hostId
            self.paneId = paneId
        }
    }

    /// The portal host that currently owns the panel's portal binding, if any.
    public private(set) var activeLease: Lease?

    /// A pending one-shot force-distinct replacement keyed by pane, set by
    /// ``prepareReplacementForNextDistinctClaim(inPane:)``.
    public private(set) var pendingDistinctReplacementPaneId: UUID?

    /// The same-pane replacement lock, if any.
    public private(set) var lockedHost: Lock?

    /// Creates a lease machine seeded from the panel's current lease state.
    public init(
        activeLease: Lease? = nil,
        pendingDistinctReplacementPaneId: UUID? = nil,
        lockedHost: Lock? = nil
    ) {
        self.activeLease = activeLease
        self.pendingDistinctReplacementPaneId = pendingDistinctReplacementPaneId
        self.lockedHost = lockedHost
    }

    /// A reset machine with no active lease, no pending replacement, and no lock,
    /// matching the legacy three-field reset used on web-view recreation and
    /// context reset.
    public func cleared() -> BrowserPortalHostLeaseMachine {
        BrowserPortalHostLeaseMachine()
    }

    /// The visible area of a bounds rectangle, mirroring the legacy
    /// `portalHostArea(for:)` (negative dimensions clamp to zero).
    public static func portalHostArea(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    /// A `#if DEBUG` log marker the panel should emit, naming the exact legacy log
    /// event and carrying the field context the legacy log line interpolated.
    ///
    /// The panel supplies its own `panel=…` prefix and `reason=…`; the machine
    /// supplies the host/pane/window/area context for the claimant and (where the
    /// legacy line logged them) the replaced/owning incumbent and the lock flag.
    public enum DebugEvent: Sendable, Equatable {
        /// `browser.portal.host.rearm` (from
        /// ``prepareReplacementForNextDistinctClaim(inPane:)``).
        case rearm(paneId: UUID)

        /// `browser.portal.host.skip` with the `.localInlineDevTools` reason suffix,
        /// logged when the claim is short-circuited by inline developer-tools hosting.
        case skipLocalInlineDevTools(host: ObjectIdentifier, paneId: UUID, inWindow: Bool, bounds: CGRect)

        /// `browser.portal.host.claim` over a previous incumbent, with `forced=1`
        /// when the force-distinct path won.
        case claimReplacing(
            host: ObjectIdentifier,
            paneId: UUID,
            inWindow: Bool,
            bounds: CGRect,
            replacing: Lease,
            forced: Bool
        )

        /// `browser.portal.host.skip` because the incumbent kept ownership, carrying
        /// the owner context and whether the same-pane lock blocked the replacement.
        case skipOwner(
            host: ObjectIdentifier,
            paneId: UUID,
            inWindow: Bool,
            bounds: CGRect,
            owner: Lease,
            locked: Bool
        )

        /// `browser.portal.host.claim` with `replacingHost=nil` (no prior lease).
        case claimFresh(host: ObjectIdentifier, paneId: UUID, inWindow: Bool, bounds: CGRect)

        /// `browser.portal.host.release` (from ``release(hostId:)``).
        case release(host: ObjectIdentifier, released: Lease)
    }

    /// The result of a ``claim(hostId:paneId:inWindow:bounds:usesLocalInlineDeveloperToolsHosting:)``
    /// call: the verdict, the next machine state to adopt, and the debug markers to
    /// emit. The panel applies these in order: adopt `machine`, emit `debugEvents`,
    /// return `claimed`.
    public struct ClaimOutcome: Sendable, Equatable {
        /// Whether the claim won (or kept) ownership.
        public let claimed: Bool

        /// The machine state the panel should adopt.
        public let machine: BrowserPortalHostLeaseMachine

        /// `#if DEBUG` markers the panel should log, in order.
        public let debugEvents: [DebugEvent]

        public init(
            claimed: Bool,
            machine: BrowserPortalHostLeaseMachine,
            debugEvents: [DebugEvent] = []
        ) {
            self.claimed = claimed
            self.machine = machine
            self.debugEvents = debugEvents
        }
    }

    /// The result of a ``release(hostId:)`` call.
    public struct ReleaseOutcome: Sendable, Equatable {
        /// Whether the calling host owned the lease and the release took effect.
        public let released: Bool

        /// The machine state the panel should adopt.
        public let machine: BrowserPortalHostLeaseMachine

        /// `#if DEBUG` markers the panel should log, in order.
        public let debugEvents: [DebugEvent]

        public init(
            released: Bool,
            machine: BrowserPortalHostLeaseMachine,
            debugEvents: [DebugEvent] = []
        ) {
            self.released = released
            self.machine = machine
            self.debugEvents = debugEvents
        }
    }

    /// The result of ``prepareReplacementForNextDistinctClaim(inPane:)``.
    public struct PrepareReplacementOutcome: Sendable, Equatable {
        /// The machine state the panel should adopt.
        public let machine: BrowserPortalHostLeaseMachine

        /// `#if DEBUG` markers the panel should log, in order.
        public let debugEvents: [DebugEvent]

        public init(machine: BrowserPortalHostLeaseMachine, debugEvents: [DebugEvent] = []) {
            self.machine = machine
            self.debugEvents = debugEvents
        }
    }

    /// Arms a one-shot force-distinct replacement for the next claim in `paneId`,
    /// dropping any same-pane lock, mirroring the legacy
    /// `preparePortalHostReplacementForNextDistinctClaim(inPane:reason:)`.
    public func prepareReplacementForNextDistinctClaim(inPane paneId: PaneID) -> PrepareReplacementOutcome {
        var next = self
        next.pendingDistinctReplacementPaneId = paneId.id
        if next.lockedHost?.paneId == paneId.id {
            next.lockedHost = nil
        }
        return PrepareReplacementOutcome(machine: next, debugEvents: [.rearm(paneId: paneId.id)])
    }

    /// Decides whether `hostId` claims (or keeps) the portal binding for `paneId`,
    /// returning the verdict, the next machine state, and the side effects to apply.
    ///
    /// This is a faithful lift of the legacy `claimPortalHost(...)`: the inline
    /// developer-tools short-circuit (clears the lease and lock, returns `false`),
    /// the same-host refresh, the force-distinct path (sets the lock), the
    /// area-gain/usability replacement, and the skip path. Eligibility for inline
    /// developer-tools hosting is decided app-side and passed in as
    /// `usesLocalInlineDeveloperToolsHosting`.
    public func claim(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        inWindow: Bool,
        bounds: CGRect,
        usesLocalInlineDeveloperToolsHosting: Bool
    ) -> ClaimOutcome {
        if usesLocalInlineDeveloperToolsHosting {
            var next = self
            next.activeLease = nil
            next.lockedHost = nil
            return ClaimOutcome(
                claimed: false,
                machine: next,
                debugEvents: [
                    .skipLocalInlineDevTools(
                        host: hostId,
                        paneId: paneId.id,
                        inWindow: inWindow,
                        bounds: bounds
                    )
                ]
            )
        }

        let nextLease = Lease(
            hostId: hostId,
            paneId: paneId.id,
            inWindow: inWindow,
            area: Self.portalHostArea(for: bounds)
        )

        guard let current = activeLease else {
            var next = self
            next.activeLease = nextLease
            return ClaimOutcome(
                claimed: true,
                machine: next,
                debugEvents: [
                    .claimFresh(host: hostId, paneId: paneId.id, inWindow: inWindow, bounds: bounds)
                ]
            )
        }

        var next = self
        if let lock = next.lockedHost,
           (lock.hostId != current.hostId || lock.paneId != current.paneId) {
            next.lockedHost = nil
        }

        if current.hostId == hostId {
            next.activeLease = nextLease
            return ClaimOutcome(claimed: true, machine: next)
        }

        let currentUsable = current.isUsable
        let isSamePaneReplacement = current.paneId == paneId.id
        let shouldForceDistinctReplacement =
            isSamePaneReplacement &&
            next.pendingDistinctReplacementPaneId == paneId.id &&
            inWindow
        if shouldForceDistinctReplacement {
            next.activeLease = nextLease
            next.pendingDistinctReplacementPaneId = nil
            next.lockedHost = Lock(hostId: hostId, paneId: paneId.id)
            return ClaimOutcome(
                claimed: true,
                machine: next,
                debugEvents: [
                    .claimReplacing(
                        host: hostId,
                        paneId: paneId.id,
                        inWindow: inWindow,
                        bounds: bounds,
                        replacing: current,
                        forced: true
                    )
                ]
            )
        }

        let lockBlocksSamePaneReplacement =
            isSamePaneReplacement &&
            currentUsable &&
            next.lockedHost?.hostId == current.hostId &&
            next.lockedHost?.paneId == current.paneId
        let shouldReplace =
            current.paneId != paneId.id ||
            !currentUsable ||
            (
                !lockBlocksSamePaneReplacement &&
                nextLease.isUsable &&
                nextLease.area > (current.area * Self.portalHostReplacementAreaGainRatio)
            )

        if shouldReplace {
            if next.lockedHost?.hostId == current.hostId &&
                next.lockedHost?.paneId == current.paneId {
                next.lockedHost = nil
            }
            next.activeLease = nextLease
            return ClaimOutcome(
                claimed: true,
                machine: next,
                debugEvents: [
                    .claimReplacing(
                        host: hostId,
                        paneId: paneId.id,
                        inWindow: inWindow,
                        bounds: bounds,
                        replacing: current,
                        forced: false
                    )
                ]
            )
        }

        return ClaimOutcome(
            claimed: false,
            machine: next,
            debugEvents: [
                .skipOwner(
                    host: hostId,
                    paneId: paneId.id,
                    inWindow: inWindow,
                    bounds: bounds,
                    owner: current,
                    locked: lockBlocksSamePaneReplacement
                )
            ]
        )
    }

    /// Releases the lease when `hostId` owns it, returning the verdict, next state,
    /// and the release marker, mirroring the legacy `releasePortalHostIfOwned`.
    public func release(hostId: ObjectIdentifier) -> ReleaseOutcome {
        guard let current = activeLease, current.hostId == hostId else {
            return ReleaseOutcome(released: false, machine: self)
        }
        var next = self
        next.activeLease = nil
        if next.lockedHost?.hostId == hostId {
            next.lockedHost = nil
        }
        return ReleaseOutcome(
            released: true,
            machine: next,
            debugEvents: [.release(host: hostId, released: current)]
        )
    }
}
