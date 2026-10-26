public import CmuxNextDesign

/// Where a motion kind's springs run.
public nonisolated enum MotionBackend: String, Sendable {
    /// The main thread steps the kind's springs on every display frame and lays its views out at
    /// each stepped value (`ScreenContentView.step`, `applyPresentation`).
    case cpuStep
    /// The kind's views go to rest once in the change's turn and Core Animation runs the springs
    /// on the render server, as Chromium runs transform and opacity animations on the compositor
    /// (`cc/animation/animation_host.h`, `keyframe_model.h`): no main-thread work per motion frame.
    case renderServer
}

/// A kind's render-server variant, with the one entry point its motion starts from.
public protocol RenderServerMotion<Host> {
    associatedtype Host
    /// The kind this variant animates.
    var kind: LayoutMotionKind { get }
    /// Called in the turn of every change on `host` (and only with the render server selected):
    /// when the change starts or retargets a motion of ``kind``, sets each moving view to its rest,
    /// lays it out once and adds its render-server springs, so the CPU step finds that motion at
    /// rest. Returns true when it took a motion; false leaves it to the CPU step.
    func begin(on host: Host, policy: MotionPolicy) -> Bool
}

/// The backend of each motion kind of a host: ``MotionBackend/renderServer`` only for a kind with
/// a registered variant while `motion.renderServer` is on (``LayoutTunables/motionRenderServer``,
/// off by default); every other kind stays on ``MotionBackend/cpuStep``.
public struct MotionBackends<Host> {
    /// One variant per kind, in registration order (the order their motions start in).
    private let variants: [any RenderServerMotion<Host>]
    private let renderServer: () -> Bool

    /// `variants`: the host's registration; a kind registered twice keeps its first variant.
    /// `renderServer`: reads the tunable (injected in tests).
    public init(_ variants: [any RenderServerMotion<Host>],
                renderServer: @escaping () -> Bool = { LayoutTunables.motionRenderServer.value }) {
        var kinds: Set<LayoutMotionKind> = []
        self.variants = variants.filter { kinds.insert($0.kind).inserted }
        self.renderServer = renderServer
    }

    /// The kinds with a render-server variant.
    public var registeredKinds: [LayoutMotionKind] { variants.map(\.kind) }

    /// The backend `kind` runs on now.
    public func backend(for kind: LayoutMotionKind) -> MotionBackend {
        variants.contains { $0.kind == kind } && renderServer() ? .renderServer : .cpuStep
    }

    /// A change on `host`: each registered kind starts its motion on the render server. Returns
    /// the kinds that took one. With the tunable off (or nothing registered) it calls nothing.
    @discardableResult
    public func begin(on host: Host, policy: MotionPolicy) -> Set<LayoutMotionKind> {
        guard !variants.isEmpty, renderServer() else { return [] }
        var took: Set<LayoutMotionKind> = []
        for variant in variants where variant.begin(on: host, policy: policy) { took.insert(variant.kind) }
        return took
    }
}
