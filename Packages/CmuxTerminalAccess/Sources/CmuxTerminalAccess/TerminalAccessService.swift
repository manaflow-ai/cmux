// SPDX-License-Identifier: MIT

/// Transport-neutral entry point that every cmux terminal-access
/// caller (Unix socket, CLI, HTTP) routes through.
///
/// Per D1 the protocol is `async` and `Sendable`; per Errata E3 the
/// `allowRawInput` setting is **not** on the protocol — it is owned
/// by ``DefaultTerminalAccessService`` as an init-time closure
/// (`allowRawInput: () -> Bool`). The HTTP layer in Phase 1 wires
/// `{ settings.allowRawInput }` at construction.
public protocol TerminalAccessService: Sendable {
    /// Enumerate every visible surface, in canonical sidebar order.
    func listSurfaces() async throws -> [SurfaceInfo]

    /// Read a screen with the requested format/region/wrap/trim.
    ///
    /// - Throws: ``TerminalAccessError/unknownSurface`` when the
    ///   handle does not resolve;
    ///   ``TerminalAccessError/unsupported(reason:)`` for Phase 0
    ///   `format=cells` and `wrap=join` (HTTP 415 per D18) until
    ///   ghostty patch #1 lands in Phase 1.
    func readScreen(_ request: ScreenReadRequest) async throws -> ScreenReadResult

    /// Write input to a surface.
    ///
    /// - Throws: ``TerminalAccessError`` on gate or policy violations.
    ///   D17 — when `request.focusSurface == true` the service moves
    ///   in-app focus **before** dispatching the payload. D30 —
    ///   `.paste` payloads are serialized per-surface so concurrent
    ///   pastes never interleave byte slices.
    func writeInput(_ request: InputRequest) async throws
}

public extension TerminalAccessService {
    /// Subscribe to a surface's live output.
    ///
    /// The returned ``OutputSubscription`` (D22) is the unit of
    /// cancellation and the carrier of `onEnd` / `signalEnd` semantics.
    /// Caller pumps frames via the subscription's
    /// ``OutputSubscription/events()`` `AsyncStream`, or via the
    /// `onEvent` closure (used by non-Task call sites such as the SSE
    /// writer).
    ///
    /// Default extension implementation traps — concrete services
    /// (notably ``DefaultTerminalAccessService``) override it.
    ///
    /// - Parameters:
    ///   - options: ``StreamSubscriptionOptions`` describing the
    ///     surface, mode, and optional `lastEventID` resume cursor.
    ///   - onEvent: Fired for every event delivered to the subscriber.
    /// - Throws: ``TerminalAccessError`` on gate or policy violations.
    /// - Returns: A live ``OutputSubscription`` whose `mode` matches
    ///   ``StreamSubscriptionOptions/mode``.
    func subscribeOutput(
        _ options: StreamSubscriptionOptions,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        fatalError("subscribeOutput must be overridden by the concrete service")
    }
}
