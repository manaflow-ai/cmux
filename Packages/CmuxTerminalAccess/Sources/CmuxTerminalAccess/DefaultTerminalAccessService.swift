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
        switch request.format {
        case .text:
            // Phase 1: ``wrap`` and ``trim`` are policy knobs applied
            // here. Until Task 1.22b retires ``ScreenRegionReader``,
            // the provider's text read returns rows already separated
            // by hard newlines; `wrap=join` is a no-op pass-through
            // for stub providers and gets the real join treatment
            // once the cells path lands.
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
            // Per Errata E20 ``readCells`` is a required protocol
            // member; conformers that lack ghostty patch #1 throw
            // ``TerminalAccessError/unsupported(reason:)`` (HTTP 415
            // per D18). The route layer maps that to the wire.
            let g = try await provider.readCells(surface: info, region: request.region)
            return .cells(g)
        }
    }

    /// Dispatch the request to the provider after enforcing every
    /// Phase 0 invariant.
    ///
    /// In order:
    ///
    /// 1. Resolve the handle to a live ``SurfaceInfo``; throw
    ///    ``TerminalAccessError/unknownSurface`` on miss.
    /// 2. Acquire a token from the per-surface rate limiter (E16 —
    ///    throws ``TerminalAccessError/rateLimited`` when empty).
    /// 3. If `request.focusSurface == true`, call
    ///    ``SurfaceProvider/setFocus(surface:gained:)`` with
    ///    `gained: true` (D17). This runs **before** the payload
    ///    dispatches.
    /// 4. Dispatch by payload kind. Byte-carrying payloads
    ///    (`.text`, `.paste`, `.raw`) run
    ///    ``enforceCapacity(info:bytes:)`` **before** any provider
    ///    write (E14). `.paste` runs the body inside the per-surface
    ///    ``PasteSerializer`` (D30). `.raw` is rejected unless
    ///    `allowRawInput()` returns `true` (D9 / E3).
    /// 5. Emit a write audit entry (D4 — always-on, E2 — async
    ///    non-throwing).
    public func writeInput(_ request: InputRequest) async throws {
        guard let info = try await provider.resolve(request.handle) else {
            throw TerminalAccessError.unknownSurface
        }
        // E16 — rate-limit per surface before any side effect. The
        // key format matches `HTTPControlRateKeys.write(for:)` in the
        // app target so wire-side audit tooling can join across both
        // sides without an extra mapping layer.
        try await rateLimiter.acquire(
            key: "surface:\(request.handle.stringValue)#write"
        )
        // D17 — explicit focus opt-in fires BEFORE the payload dispatches.
        if request.focusSurface {
            try await provider.setFocus(surface: info, gained: true)
        }
        switch request.payload {
        case .text(let s, let submit):
            let bytes = Data(s.utf8)
            try await enforceCapacity(info: info, bytes: bytes.count)
            try await provider.writeText(surface: info, bytes: bytes)
            if submit {
                try await provider.writeKey(
                    surface: info,
                    event: KeyEvent(mods: [], key: .enter)
                )
            }
            await audit.record(
                AuditEntry(
                    timestamp: Date(),
                    surface: request.handle,
                    kind: .writeText,
                    byteCount: bytes.count,
                    detail: ["submit": "\(submit)"]
                )
            )
        case .paste(let s):
            // D30 — serialize wrap+write per-surface so concurrent
            // pastes cannot interleave byte slices.
            let bytes = Data(s.utf8)
            try await enforceCapacity(info: info, bytes: bytes.count)
            try await pasteSerializer.run(surface: info) {
                try await self.provider.writeText(surface: info, bytes: bytes)
            }
            await audit.record(
                AuditEntry(
                    timestamp: Date(),
                    surface: request.handle,
                    kind: .writePaste,
                    byteCount: bytes.count,
                    detail: nil
                )
            )
        case .keys(let events):
            for ev in events {
                try await provider.writeKey(surface: info, event: ev)
            }
            await audit.record(
                AuditEntry(
                    timestamp: Date(),
                    surface: request.handle,
                    kind: .writeKeys,
                    byteCount: events.count,
                    detail: nil
                )
            )
        case .raw(let data):
            if !allowRawInput() {
                throw TerminalAccessError.forbidden(reason: "raw input disabled")
            }
            try await enforceCapacity(info: info, bytes: data.count)
            try await provider.writeText(surface: info, bytes: data)
            await audit.record(
                AuditEntry(
                    timestamp: Date(),
                    surface: request.handle,
                    kind: .writeRaw,
                    byteCount: data.count,
                    detail: nil
                )
            )
        case .mouse(let ev):
            // D16 — direct provider call; provider must NOT
            // synthesize NSEvent instances.
            try await provider.writeMouse(surface: info, event: ev)
            await audit.record(
                AuditEntry(
                    timestamp: Date(),
                    surface: request.handle,
                    kind: .writeMouse,
                    byteCount: 0,
                    detail: ["action": ev.action.rawValue]
                )
            )
        case .focus(let gained):
            try await provider.setFocus(surface: info, gained: gained)
            await audit.record(
                AuditEntry(
                    timestamp: Date(),
                    surface: request.handle,
                    kind: .writeFocus,
                    byteCount: 0,
                    detail: ["gained": "\(gained)"]
                )
            )
        }
    }

    /// Subscribe to a surface's live output (Phase 2 entry point).
    ///
    /// Acquires a per-surface ``StreamCap`` slot, resolves the handle,
    /// and dispatches to ``openRawSubscription(info:options:capToken:onEvent:)``
    /// or ``openCellsSubscription(info:options:capToken:onEvent:)`` based
    /// on ``StreamSubscriptionOptions/mode``.
    ///
    /// Raw mode throws ``TerminalAccessError/unsupported(reason:)``
    /// until the ghostty patch #2 PTY tee lands; cells mode delegates
    /// to ``SnapshotPoller`` (D8).
    public func subscribeOutput(
        _ options: StreamSubscriptionOptions,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        guard let capToken = streamCap.acquire(surface: options.handle) else {
            // D7 — per-surface cap exhausted; transports map to 503.
            throw TerminalAccessError.rateLimited
        }
        let info: SurfaceInfo
        do {
            guard let resolved = try await provider.resolve(options.handle) else {
                capToken.release()
                throw TerminalAccessError.unknownSurface
            }
            info = resolved
        } catch {
            capToken.release()
            throw error
        }

        switch options.mode {
        case .raw:
            return try await openRawSubscription(
                info: info, options: options,
                capToken: capToken, onEvent: onEvent
            )
        case .cells:
            return try await openCellsSubscription(
                info: info, options: options,
                capToken: capToken, onEvent: onEvent
            )
        }
    }

    /// Raw mode is gated until ghostty patch #2 wires the PTY tee +
    /// `SurfaceProvider.attachRawOutput` seam (Task 2.15). Until then
    /// the service throws ``TerminalAccessError/unsupported(reason:)``
    /// (HTTP 415 per D18) and releases the cap token before bubbling
    /// the error to the caller.
    private func openRawSubscription(
        info: SurfaceInfo,
        options: StreamSubscriptionOptions,
        capToken: StreamCap.Token,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        capToken.release()
        throw TerminalAccessError.unsupported(
            reason: "raw_stream_unavailable: pending ghostty patch #2"
        )
    }

    /// Open a ``StreamMode/cells`` subscription backed by
    /// ``SnapshotPoller`` (D8).
    ///
    /// The poller calls
    /// ``SurfaceProvider/readCells(surface:region:)`` every
    /// ``cellsTickRate`` ticks, hashes the resulting ``CellGrid`` with
    /// ``CellGridDigest`` (FNV-1a over codepoints + cursor) and emits
    /// only when the digest changes. Each emit appends one
    /// ``OutputEvent/cellsSnapshot(_:seq:)`` into a per-subscriber
    /// ``EventRing`` (capacity 256) and drains everything newer than
    /// the caller's `lastEventID` into `onEvent`.
    ///
    /// Cancellation stops the poller and releases the per-surface
    /// ``StreamCap`` slot; an audit `streamClose` entry is recorded
    /// fire-and-forget per E2.
    ///
    /// - Note: the poller is intentionally polling-based, not a third
    ///   ghostty patch (plan §15 open question).
    private func openCellsSubscription(
        info: SurfaceInfo,
        options: StreamSubscriptionOptions,
        capToken: StreamCap.Token,
        onEvent: @escaping @Sendable (OutputEvent) -> Void
    ) async throws -> OutputSubscription {
        let ring = EventRing(capacity: 256)
        let surface = info
        let provider = self.provider

        // Track the highest seq delivered to `onEvent` so each drain
        // returns only newly-appended entries. Start at the caller's
        // `lastEventID` so resumes do not re-emit already-acknowledged
        // events (D6). When the requested id is below the ring's oldest
        // seq, the HTTP layer will additionally write the synthetic
        // `: gap` SSE comment (Task 2.24).
        let lastDeliveredLock = NSLock()
        nonisolated(unsafe) var lastDelivered: UInt64 = options.lastEventID ?? 0

        let poller = SnapshotPoller(
            interval: max(0.001, 1.0 / cellsTickRate),
            clock: SystemMonotonicClock(),
            read: {
                try await provider.readCells(surface: surface, region: .viewport)
            },
            emit: { grid in
                _ = ring.append(.cellsSnapshot(grid, seq: 0))
                lastDeliveredLock.lock()
                let after = lastDelivered
                lastDeliveredLock.unlock()
                for (s, ev) in ring.drain(after: after) {
                    onEvent(ev)
                    lastDeliveredLock.lock()
                    lastDelivered = s
                    lastDeliveredLock.unlock()
                }
            }
        )

        // Audit open (E2 — async non-throwing) before the timer fires
        // so the close entry never appears before the open entry.
        await audit.record(
            AuditEntry(
                timestamp: Date(),
                surface: options.handle,
                kind: .streamOpen,
                byteCount: 0,
                detail: ["mode": "cells", "tickRate": "\(cellsTickRate)"]
            )
        )

        // Drive the poller from a wall-clock GCD timer. The actor-based
        // tick() is non-reentrant; if a previous tick is still running
        // we silently coalesce — that's the right behavior for D8 where
        // a slow read should not pile up backlog ticks.
        let label = "cmux.stream.cells.\(UUID().uuidString)"
        let timerQueue = DispatchQueue(label: label, qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        let intervalMs = max(5, Int(1000.0 / cellsTickRate))
        timer.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs)
        )
        timer.setEventHandler { [poller] in
            Task { try? await poller.tick() }
        }
        timer.resume()

        let audit = self.audit
        let sub = OutputSubscription(
            id: UUID(),
            handle: options.handle,
            mode: .cells,
            onCancel: {
                timer.cancel()
                capToken.release()
                Task { @Sendable in
                    await audit.record(
                        AuditEntry(
                            timestamp: Date(),
                            surface: options.handle,
                            kind: .streamClose,
                            byteCount: 0,
                            detail: ["mode": "cells"]
                        )
                    )
                }
            }
        )

        // Phase 2 close detection (Task 2.19) — the provider fires
        // `onClose` exactly once when the surface goes away; we forward
        // that to ``OutputSubscription/signalEnd()`` so the SSE writer
        // can emit a terminal `event: end` frame. The returned token
        // is retained for the subscription lifetime via
        // ``OutputSubscription/attachLifetime(_:)``.
        let closeToken = try await provider.observeClose(options.handle) {
            [weak sub] in sub?.signalEnd()
        }
        sub.attachLifetime(closeToken)
        return sub
    }

    /// Per E14 — gate runs before any provider call that writes
    /// bytes. The capacity reader is synchronous per E1.
    private func enforceCapacity(info: SurfaceInfo, bytes: Int) async throws {
        let remaining = provider.pendingInputCapacityRemaining(surface: info)
        if bytes > remaining {
            throw TerminalAccessError.payloadTooLarge
        }
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
