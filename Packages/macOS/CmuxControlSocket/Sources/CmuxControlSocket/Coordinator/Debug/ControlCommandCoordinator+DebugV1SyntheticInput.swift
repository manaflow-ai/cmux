#if DEBUG
internal import Foundation

/// The pure parse/decision/payload halves of the v1-only synthetic-input
/// probes `simulate_type` and `simulate_file_drop`.
///
/// Each method owns the argument parsing, the verbatim usage-error strings, and
/// the response formatting the legacy `TerminalController` v1 bodies built; the
/// irreducible live-state reads stay app-side behind the narrowed
/// ``ControlDebugContext`` witnesses (which take already-parsed, typed inputs):
/// `simulate_type` inserts the decoded text at the live key window's first
/// responder, and `simulate_file_drop` resolves the target terminal surface and
/// synthesizes the drop on its hosted view. Both commands exist only on the v1
/// line protocol (no v2 method).
extension ControlCommandCoordinator {
    /// The v1 `simulate_type` body: trims the raw argument (rejecting an empty
    /// argument with the verbatim usage `ERROR`), decodes the line-protocol
    /// backslash escapes, drives the live first-responder insert through the
    /// seam, and reconstructs the legacy `"OK"`/`ERROR…` response.
    ///
    /// - Parameter args: The raw `simulate_type` argument line.
    /// - Returns: `"OK"` on insertion, or a verbatim `ERROR…` line (bad usage or
    ///   an unavailable live precondition).
    func debugSimulateTypeV1(_ args: String) -> String {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: simulate_type <text>"
        }

        // Socket commands are line-based; allow callers to express control chars
        // with backslash escapes.
        let text = raw.socketTextEscapesDecoded

        // An unwired context reads as `noWindow` — unreachable in practice (the
        // composition owner wires the context during init); it reproduces the
        // legacy `"ERROR: No window"` initial value.
        let resolution = debugContext?.controlDebugSimulateType(decodedText: text) ?? .noWindow
        switch resolution {
        case .noWindow:
            return "ERROR: No window"
        case .noFirstResponder:
            return "ERROR: No first responder"
        case .inserted:
            return "OK"
        }
    }

    /// The v1 `simulate_file_drop` body: splits the
    /// `<id|idx> <path[|path…]>` argument (rejecting a missing path list or an
    /// all-empty path list with the verbatim usage `ERROR`), drives the live
    /// surface resolution + drop synthesis through the seam, and reconstructs
    /// the legacy `"OK"`/`ERROR…` response.
    ///
    /// The live `TabManager`-availability check stays AHEAD of the parse so that
    /// a malformed argument issued while `TabManager` is unavailable still
    /// returns `"ERROR: TabManager not available"`, exactly as the legacy body's
    /// leading `guard let tabManager` ordering did (it ran before any parsing).
    ///
    /// - Parameter args: The raw `simulate_file_drop` argument line.
    /// - Returns: `"OK"` on a synthesized drop, or a verbatim `ERROR…` line.
    func debugSimulateFileDropV1(_ args: String) -> String {
        // An unwired context reads as unavailable — unreachable in practice (the
        // composition owner wires the context during init); it reproduces the
        // legacy leading `"ERROR: TabManager not available"` guard.
        guard debugContext?.controlDebugTabManagerAvailable() == true else {
            return "ERROR: TabManager not available"
        }

        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        let target = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPaths = parts[1]
        let paths = rawPaths
            .split(separator: "|")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            return "ERROR: Usage: simulate_file_drop <id|idx> <path[|path...]>"
        }

        // The TabManager-availability guard above already ran, so the witness's
        // own `tabManagerUnavailable` is unreachable here; map it to the same
        // legacy line to stay total.
        let resolution = debugContext?.controlDebugSimulateFileDrop(
            target: target,
            paths: paths
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return "ERROR: TabManager not available"
        case .surfaceNotFound:
            return "ERROR: Surface not found"
        case .dropped:
            return "OK"
        case .dropFailed:
            return "ERROR: Failed to simulate drop"
        }
    }
}
#endif
