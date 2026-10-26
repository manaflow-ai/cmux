public import CmuxNextDesignTokens

/// Where a motion kind's springs run in one change.
public nonisolated enum MotionBackend: String, Sendable {
    /// The main thread steps the kind's springs on every display frame and lays its views out at
    /// each stepped value.
    case cpuStep
    /// Core Animation runs the kind's springs on the render server, as Chromium runs transform and
    /// opacity animations on the compositor (`cc/animation/animation_host.h`, `keyframe_model.h`):
    /// no main-thread work per motion frame.
    case renderServer
}

/// A kind's render-server variant: the one entry point its motion starts from.
public protocol RenderServerMotion<Host> {
    associatedtype Host
    /// The kind this variant animates.
    var kind: RenderMotionKind { get }
    /// Called once at the end of every change turn on `host` (and only while the render server is
    /// selected), after the turn started all its motions and before the turn lays anything out.
    ///
    /// When the change started or retargeted a motion of ``kind``, the variant adds its
    /// render-server springs, leaves that kind's CPU spring state at rest and returns
    /// ``MotionBackend/renderServer``. The host then skips the kind's CPU first frame, lays the
    /// change out once at rest and asks for no display frames for it. ``MotionBackend/cpuStep``
    /// leaves the motion to the main thread as before.
    func begin(on host: Host, policy: MotionPolicy) -> MotionBackend
}

/// A host's render-server variants and the switch that selects them (`motion.renderServer`, off by
/// default). With the switch off or nothing registered, no variant runs and every kind steps on the
/// main thread.
public struct MotionBackends<Host> {
    /// One variant per kind, in registration order (the order their motions start in).
    private let variants: [any RenderServerMotion<Host>]
    private let renderServer: () -> Bool

    /// `variants`: the host's registration, each kind at most once. `renderServer`: whether the
    /// render server is selected; read in each change turn, and never with nothing registered.
    public init(_ variants: [any RenderServerMotion<Host>], renderServer: @escaping () -> Bool) {
        assert(Set(variants.map(\.kind)).count == variants.count, "a render-server motion kind is registered twice")
        self.variants = variants
        self.renderServer = renderServer
    }

    /// A variant is registered and the render server is selected: a change turn may hand motions to it.
    public var isLive: Bool { !variants.isEmpty && renderServer() }

    /// The end of a change turn on `host`: each registered kind may take the motion the change
    /// started. Returns the kinds now on the render server.
    public func begin(on host: Host, policy: MotionPolicy) -> Set<RenderMotionKind> {
        guard isLive else { return [] }
        var taken: Set<RenderMotionKind> = []
        for variant in variants where variant.begin(on: host, policy: policy) == .renderServer {
            taken.insert(variant.kind)
        }
        return taken
    }
}
