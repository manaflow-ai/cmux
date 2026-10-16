public import CMUXMobileCore
public import Foundation

/// Injects phase recording without making the terminal package reach into app state.
public struct TerminalSurfaceWorkDiagnostics {
    private let log: DiagnosticLog?
    private let context: @MainActor (UUID) -> TerminalWorkContext

    /// Creates the optional diagnostics seam.
    /// - Parameters:
    ///   - log: The app-owned bounded diagnostic ring; nil disables recording.
    ///   - context: Snapshots the owning window's population on the main actor.
    public init(
        log: DiagnosticLog? = nil,
        context: @escaping @MainActor (UUID) -> TerminalWorkContext = { _ in .init() }
    ) {
        self.log = log
        self.context = context
    }

    /// Begins a real size mutation after redundant geometry has been filtered.
    /// - Parameters:
    ///   - phase: The actual API boundary being entered.
    ///   - workspaceID: Used locally to resolve counts; never recorded.
    /// - Returns: An optional completion token for the measured API call.
    @MainActor
    public func begin(_ phase: TerminalWorkDiagnostic.Phase, workspaceID: UUID) -> TerminalWorkInterval? {
        guard let log else { return nil }
        return log.beginTerminalWork(phase, context: context(workspaceID))
    }
}
