// SPDX-License-Identifier: MIT

import Foundation

/// Default ``TerminalAccessService`` used by every cmux transport.
///
/// Phase 0 ships the text-read path and the write-input fanout (Task
/// 0.20). ``ScreenFormat/cells`` and ``WrapPolicy/join`` throw
/// ``TerminalAccessError/unsupported(reason:)`` (HTTP 415, D18) until
/// ghostty patch #1 lands in Phase 1.
///
/// Per D30 paste calls are serialized per surface via a private
/// ``PasteSerializer`` keyed by surface UUID, so concurrent pastes
/// never interleave. Per D17 `request.focusSurface == true` calls
/// ``SurfaceProvider/setFocus(surface:gained:)`` **before**
/// dispatching the payload. Per D16 mouse events go straight to
/// ``SurfaceProvider/writeMouse(surface:event:)`` without
/// synthesizing `NSEvent` instances. Per D4 every write path emits
/// an audit entry unconditionally — Settings only controls the log
/// path, never whether logging happens.
///
/// Per Errata E3 the init signature is locked so Phase 1/2 only need
/// to **pass values** for the dependencies:
/// `(provider:audit:rateLimiter:streamCap:cellsTickRate:allowRawInput:)`.
public final class DefaultTerminalAccessService: TerminalAccessService, @unchecked Sendable {
    private let provider: any SurfaceProvider
    private let audit: any AuditLog
    private let rateLimiter: RateLimiter
    private let streamCap: StreamCap
    private let cellsTickRate: Double
    private let allowRawInput: () -> Bool
    /// Per-surface paste serializer (Errata E4 — defined once in
    /// its own file as a public actor).
    private let pasteSerializer = PasteSerializer()

    /// Creates the service.
    ///
    /// - Parameters:
    ///   - provider: Live surface registry seam.
    ///   - audit: Audit sink. Production wires
    ///     ``FileAuditLog``; tests can pass ``NoOpAuditLog``.
    ///   - rateLimiter: Token-bucket limiter; default is a Phase 0
    ///     conservative bucket so tests do not flake.
    ///   - streamCap: Per-surface SSE concurrency cap (D7); default
    ///     8 per spec §9.1.
    ///   - cellsTickRate: SSE cells frame rate in Hz. Phase 2
    ///     supplies the real value.
    ///   - allowRawInput: Read-side gate for `.raw` payloads (D9 /
    ///     E3). Defaults to `{ false }` so raw is rejected unless
    ///     the embedder explicitly opts in.
    public init(
        provider: any SurfaceProvider,
        audit: any AuditLog,
        rateLimiter: RateLimiter = RateLimiter(burstCapacity: 64, refillPerSecond: 16),
        streamCap: StreamCap = StreamCap(maxPerSurface: 8),
        cellsTickRate: Double = 5.0,
        allowRawInput: @escaping () -> Bool = { false }
    ) {
        self.provider = provider
        self.audit = audit
        self.rateLimiter = rateLimiter
        self.streamCap = streamCap
        self.cellsTickRate = cellsTickRate
        self.allowRawInput = allowRawInput
    }

    public func listSurfaces() async throws -> [SurfaceInfo] {
        try await provider.listSurfaces()
    }

    public func readScreen(_ request: ScreenReadRequest) async throws -> ScreenReadResult {
        guard let info = try await provider.resolve(request.handle) else {
            throw TerminalAccessError.unknownSurface
        }
        if request.wrap == .join {
            throw TerminalAccessError.unsupported(reason: "wrap=join requires ghostty patch #1")
        }
        switch request.format {
        case .text:
            var text = try await provider.readText(surface: info, region: request.region)
            if request.trim { text = Self.trimTrailingSpaces(text) }
            return .text(
                TextScreenPayload(
                    cols: info.cols,
                    rows: info.rows,
                    altScreen: info.altScreen,
                    title: info.title,
                    text: text
                )
            )
        case .cells:
            throw TerminalAccessError.unsupported(reason: "format=cells requires ghostty patch #1")
        }
    }

    /// Placeholder. The full dispatch lands in Task 0.20.
    public func writeInput(_ request: InputRequest) async throws {
        throw TerminalAccessError.unsupported(reason: "writeInput lands in Task 0.20")
    }

    private static func trimTrailingSpaces(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var end = line.endIndex
                while end > line.startIndex {
                    let prev = line.index(before: end)
                    if line[prev] == " " || line[prev] == "\t" {
                        end = prev
                    } else {
                        break
                    }
                }
                return line[line.startIndex..<end]
            }
            .joined(separator: "\n")
    }
}
