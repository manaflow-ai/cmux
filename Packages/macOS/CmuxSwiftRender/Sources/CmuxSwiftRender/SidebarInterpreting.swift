/// Renders interpreted-sidebar source into a ``RenderNode`` tree, abstracting
/// over *where* interpretation happens.
///
/// The UI layer depends on this seam, not on a concrete interpreter, so the app
/// can inject either ``InProcessSidebarInterpreter`` (interprets in the host
/// process) or an out-of-process, crash-isolating implementation. The async
/// signature accommodates both: in-process returns immediately; an
/// out-of-process implementation awaits a worker round-trip.
///
/// A `nil` result means "no view to show" for any reason — unsupported source,
/// or (for an isolating implementation) a worker crash or timeout. The caller
/// renders its error/empty state and never has to reason about interpreter
/// faults.
public protocol SidebarInterpreting: Sendable {
    /// Interprets `source` against the live `state` data context.
    ///
    /// - Returns: the interpreted view tree, or `nil` when no view could be
    ///   produced (including isolated worker crash/timeout).
    func render(source: String, state: [String: SwiftValue]) async -> RenderNode?
}
