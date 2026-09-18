import Foundation

/// One create the person started from the sheet, alive from the moment the
/// CLI run launches until the machine exists (then the real fleet row takes
/// over) or the create fails (then the row stays, red, until retried or
/// dismissed). A running operation can be cancelled from the row without
/// waiting for the provider. Rendered by the Machines panel as a pending
/// machine row.
struct MachineCreateOperation: Identifiable, Equatable {
    enum Phase: Equatable {
        case running
        /// The provider has returned the machine id, but the authoritative
        /// fleet/catalog projection has not yet adopted it. The operation keeps
        /// its request identity so the sidebar can change the same row in place.
        case reconciling(machineID: String)
        /// The CLI exited non-zero without creating a machine; `output` is
        /// its combined stdout/stderr, or a generic line when it said nothing.
        case failed(output: String)
    }

    let id: UUID
    let request: MachineCreateRequest
    let startedAt: Date
    /// Stable machine id emitted as soon as the provider creates it. This is
    /// the only safe correlation key while the CLI is still opening the machine.
    var createdMachineID: String? = nil
    var phase: Phase = .running

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Whether this row is still waiting on authoritative projection state.
    var isReconciling: Bool {
        if case .reconciling = phase { return true }
        return false
    }

    /// Whether the local process can still be cancelled or retried.
    var isCancellable: Bool { isRunning }

    /// The authoritative machine id once the provider has acknowledged the
    /// create, used to keep the sidebar node identity stable during adoption.
    var reconcilingMachineID: String? {
        if case .reconciling(let machineID) = phase { return machineID }
        return nil
    }

    /// The CLI's failure output; nil while running.
    var failureOutput: String? {
        if case .failed(let output) = phase { return output }
        return nil
    }

    /// The one-line status beside the name: the sheet's progress wording
    /// while running, the failure headline once it failed.
    var statusLabel: String {
        switch phase {
        case .running:
            return request.progressLabel
        case .reconciling:
            return String(localized: "cloudTree.placeholder.connecting", defaultValue: "Connecting…")
        case .failed:
            return request.failureLabel
        }
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

    /// Whether the machine this create asked for is already a row of its own —
    /// the fleet list returned it, or the catalog registered it while the CLI
    /// is still opening it — so the stand-in must step aside instead of showing
    /// the same machine twice ("troll · Creating…" above "troll"). Both named
    /// and unnamed creates use the authoritative id emitted by the CLI, and
    /// remain visible until that id appears in the fleet or catalog. Base setup
    /// reopens an existing slot and a failed create stays red until retried or
    /// dismissed, so neither is ever superseded.
    func isSuperseded(by machines: [MachineSnapshot], catalogMachines: [SurfaceMachineInfo]) -> Bool {
        guard (isRunning || isReconciling), !request.isBaseSetup else { return false }
        let authoritativeID = reconcilingMachineID ?? createdMachineID
        guard let authoritativeID, !authoritativeID.isEmpty else {
            // A catalog row without the CLI's authoritative id cannot be
            // correlated safely. Keep the stand-in visible until the progress
            // marker arrives or the process exits.
            return false
        }
        for machine in machines {
            if machine.id == authoritativeID { return true }
        }
        return catalogMachines.contains { $0.id.cloudMachineID == authoritativeID }
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
