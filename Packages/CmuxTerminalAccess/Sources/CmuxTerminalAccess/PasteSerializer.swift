// SPDX-License-Identifier: MIT

import Foundation

/// Per-surface serial actor for paste atomicity (D30 / Errata E4).
///
/// Concurrent ``run(surface:_:)`` calls for the same
/// ``SurfaceInfo/uuid`` execute in FIFO order so the byte slices of
/// two pastes can never interleave. Calls for **different** surfaces
/// execute concurrently — the serialization key is `surface.uuid`.
///
/// Per Errata E4 this type lives in its own file and is **never**
/// inlined inside ``DefaultTerminalAccessService.swift``.
///
/// Example:
/// ```swift
/// let serializer = PasteSerializer()
/// try await serializer.run(surface: info) {
///     try await provider.writeText(surface: info, bytes: bytes)
/// }
/// ```
public actor PasteSerializer {
    /// Tail of the per-surface queue. The next caller awaits this
    /// task, which only completes after the previously queued body
    /// has fully run. Stored as `Task<Void, Never>` so we can store
    /// heterogenous body return types behind one type-erased tail
    /// without leaking generic constraints out of the actor.
    private var tails: [UUID: Task<Void, Never>] = [:]

    /// Creates an empty serializer with no in-flight pastes.
    public init() {}

    /// Run `body` for `surface`, after every previously queued body
    /// for that surface has completed.
    ///
    /// Throwing bodies still hand off the tail — the next queued
    /// body for the same surface starts as soon as the failing body
    /// returns. Per-surface tails are tracked by
    /// ``SurfaceInfo/uuid``; distinct surfaces are independent.
    ///
    /// - Parameters:
    ///   - surface: Identifies the per-surface queue. Surfaces with
    ///     distinct ``SurfaceInfo/uuid`` values do not block each
    ///     other.
    ///   - body: Async work to execute. Throws propagate to the
    ///     caller; the next queued body still runs.
    public func run<T: Sendable>(
        surface: SurfaceInfo,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let previous = tails[surface.uuid]
        // The body wraps result reporting via a Task<T, Error> that
        // also awaits the previous tail. We expose a parallel
        // Task<Void, Never> as the tail so the actor's state holds a
        // uniform task type independent of `T`.
        let work = Task<T, any Error> {
            await previous?.value
            return try await body()
        }
        let tail = Task<Void, Never> {
            _ = try? await work.value
        }
        tails[surface.uuid] = tail
        return try await work.value
    }
}
