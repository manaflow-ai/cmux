import ArgumentParser
import Foundation

/// Routes facade command declarations through the established legacy CLI implementation.
/// Shared by every command family so the delegation path and completion-kind
/// helpers exist in exactly one place.
///
/// Conforming commands declare every option as `String?` even when the legacy
/// parser reads it as a number. `ArgumentParser` validates and converts declared
/// types before `run()` delegates, so a numeric declaration would reject values
/// the legacy parser accepts (and would skip its fallbacks, such as defaulting an
/// unparsable `resize-pane --amount` to 1). Parsing stays with the legacy parser.
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
