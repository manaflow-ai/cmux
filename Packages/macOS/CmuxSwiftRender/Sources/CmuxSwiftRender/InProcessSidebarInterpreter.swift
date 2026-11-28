/// A ``SidebarInterpreting`` that runs the ``SwiftViewInterpreter`` in the host
/// process.
///
/// This is the non-isolated implementation: simplest and lowest-latency, but a
/// bug in the interpreter crashes the host. Use it where the source is trusted
/// or isolation is not required; use an out-of-process implementation to guard
/// against interpreter faults from untrusted sidebars.
public struct InProcessSidebarInterpreter: SidebarInterpreting {
    private let interpreter = SwiftViewInterpreter()

    public init() {}

    public func render(source: String, state: [String: SwiftValue]) async -> RenderNode? {
        interpreter.evaluate(source, state: state)
    }
}
