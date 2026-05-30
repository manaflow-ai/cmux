// SPDX-License-Identifier: MIT
//
// CmuxTerminalAccess — umbrella namespace.
//
// The package owns protocol seams (``SurfaceProvider``,
// ``TerminalAccessService``) and shared value types that every cmux
// terminal-access transport (Unix socket, CLI, HTTP) routes through.

/// Umbrella namespace for the ``CmuxTerminalAccess`` package.
///
/// The package holds the protocol seams (``SurfaceProvider``,
/// ``TerminalAccessService``) and shared value types that every cmux
/// terminal-access transport (Unix socket, CLI, HTTP) routes through.
///
/// Symbols are organised one-type-per-file under
/// `Sources/CmuxTerminalAccess/`.
public enum CmuxTerminalAccess {
    /// Package version string, surfaced for smoke tests and audit-log
    /// metadata. Bump when the public API changes meaningfully.
    public static let version = "0.1.0"
}
