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
    private var tails: [UUID: Task<Void, Never>] = [:]

    /// Creates an empty serializer with no in-flight pastes.
    public init() {}

    /// Run `body` for `surface`, after every previously queued body
    /// for that surface has completed.
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
    ) async rethrows -> T {
        let previous = tails[surface.uuid]
        let gate = Task<Void, Never> { await previous?.value }
        tails[surface.uuid] = gate
        await gate.value
        return try await body()
    }
}
