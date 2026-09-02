import Foundation

/// One create the person started from the sheet, alive from the moment the
/// CLI run launches until the machine exists (then the real fleet row takes
/// over) or the create fails (then the row stays, red, until retried or
/// dismissed). Rendered by the Machines panel as a pending machine row.
struct MachineCreateOperation: Identifiable, Equatable {
    enum Phase: Equatable {
        case running
        /// The CLI exited non-zero without creating a machine; `output` is
        /// its combined stdout/stderr, or a generic line when it said nothing.
        case failed(output: String)
    }

    let id: UUID
    let request: MachineCreateRequest
    let startedAt: Date
    var phase: Phase = .running

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// The CLI's failure output; nil while running.
    var failureOutput: String? {
        if case .failed(let output) = phase { return output }
        return nil
    }

    /// The one-line status beside the name: the sheet's progress wording
    /// while running, the failure headline once it failed.
    var statusLabel: String {
        isRunning ? request.progressLabel : request.failureLabel
    }

    /// The tooltip / accessibility line: name plus status, plus the failure's
    /// first human-readable line so hovering explains a red row.
    var summaryLine: String {
        var parts = [request.displayName, statusLabel]
        if let output = failureOutput, let reason = Self.headline(ofOutput: output) {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    /// The first line of CLI output that explains a failure: blank lines and
    /// the CLI's own "Created Cloud VM <id>" progress line are skipped (a
    /// create that failed *after* minting the machine prints that first), an
    /// `Error:` prefix is dropped, and the result is capped to fit a
    /// notification body. Nil when nothing is left.
    static func headline(ofOutput output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("OK "),
                  MachineCreateCoordinator.createdMachineID(fromOutput: line) == nil else { continue }
            if line.lowercased().hasPrefix("error:") {
                line = String(line.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            return String(line.prefix(240))
        }
        return nil
    }
}
