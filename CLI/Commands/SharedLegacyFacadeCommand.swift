import ArgumentParser
import Foundation

/// Routes facade command declarations through the established legacy CLI implementation.
/// Shared by every command family so the delegation path and completion-kind
/// helpers exist in exactly one place.
protocol SharedLegacyFacadeCommand: ParsableCommand {}

extension SharedLegacyFacadeCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }

    static var workspaceCompletion: CompletionKind { .custom(CompletionCandidates.workspaces) }
    static var surfaceCompletion: CompletionKind { .custom(CompletionCandidates.surfaces) }
    static var paneCompletion: CompletionKind { .custom(CompletionCandidates.panes) }
    static var windowCompletion: CompletionKind { .custom(CompletionCandidates.windows) }
    static var vmCompletion: CompletionKind { .custom(CompletionCandidates.vms) }
}
