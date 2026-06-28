import Foundation

/// Errors raised while talking to a remote tmux server over SSH.
enum RemoteTmuxError: Error, Sendable, Equatable {
    /// The `ssh` (or remote) command exited non-zero for a reason cmux does
    /// not treat as benign. Carries the exit code and captured stderr.
    case commandFailed(exitCode: Int32, stderr: String)

    /// The local `ssh` binary could not be launched at all.
    case launchFailed(String)

    /// The remote host is not reachable / the SSH master could not be opened.
    case unreachable(String)

    /// The remote tmux is older than ``RemoteTmuxVersion/minimumSupported``, so the
    /// control-mode mirror would attach into a broken/degraded state (no live pane
    /// subscriptions, or no `%begin`/`%end` framing). Carries the detected version
    /// string for the message.
    case unsupportedTmux(detected: String)
}

extension RemoteTmuxError {
    static var unknownVersionDisplayName: String {
        String(localized: "remoteTmux.version.unknown", defaultValue: "unknown")
    }

    /// A short, user-presentable description.
    ///
    /// Raw remote ssh/tmux stderr (and launch/unreachable detail) is sanitized before
    /// it reaches socket/CLI-facing error text: control/format/separator scalars
    /// (terminal escapes, NUL, CR, …) are flattened to spaces and the result is capped,
    /// so a noisy or hostile remote can't inject control bytes or unbounded output into
    /// our error bodies. Only the rendered `message` is sanitized — the stored
    /// associated `stderr`/`detail` are left untouched for the stderr-classification
    /// paths that pattern-match them (`indicatesNoServer`, `indicatesAuthRequired`).
    var message: String {
        switch self {
        case let .commandFailed(exitCode, stderr):
            let detail = Self.sanitizedDetail(stderr)
            if detail.isEmpty {
                let format = String(
                    localized: "remoteTmux.error.commandFailed",
                    defaultValue: "remote command failed (exit %d)"
                )
                return String(format: format, Int(exitCode))
            }
            let format = String(
                localized: "remoteTmux.error.commandFailedWithDetail",
                defaultValue: "remote command failed (exit %d): %@"
            )
            return String(format: format, Int(exitCode), detail)
        case let .launchFailed(detail):
            let format = String(
                localized: "remoteTmux.error.launchFailed",
                defaultValue: "failed to launch SSH: %@"
            )
            return String(format: format, Self.sanitizedDetail(detail))
        case let .unreachable(detail):
            let format = String(
                localized: "remoteTmux.error.unreachable",
                defaultValue: "host unreachable: %@"
            )
            return String(format: format, Self.sanitizedDetail(detail))
        case let .unsupportedTmux(detected):
            let format = String(
                localized: "remoteTmux.error.unsupportedVersion",
                defaultValue: "remote session server is too old (found %@; cmux needs version %@ or newer)"
            )
            return String(
                format: format,
                Self.sanitizedDetail(detected),
                RemoteTmuxVersion.minimumSupported.displayString
            )
        }
    }

    /// Flattens control/format/separator scalars to spaces and caps length, so raw
    /// remote diagnostics stay readable and bounded in user-facing error text. Mirrors
    /// the scalar categories rejected by `TerminalController.remoteTmuxValueHasHiddenCharacter`.
    private static func sanitizedDetail(_ raw: String) -> String {
        let space: Unicode.Scalar = " "
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                scalars.append(space)
            default:
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 200
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }
}

// `String(describing:)` and `error.localizedDescription` both surface the
// crafted ``message`` instead of the default enum reflection dump, so the
// socket/CLI error path (which maps thrown errors via `String(describing:)`)
// returns the readable form rather than `commandFailed(exitCode: 1, …)`.
extension RemoteTmuxError: CustomStringConvertible {
    var description: String { message }
}

extension RemoteTmuxError: LocalizedError {
    var errorDescription: String? { message }
}
