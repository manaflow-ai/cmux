// SPDX-License-Identifier: MIT

import Foundation
@testable import CmuxTerminalAccess

/// Shared test stub for ``SurfaceProvider`` (D13).
///
/// The single canonical definition referenced by every Phase 0/1/2
/// test that needs a fake provider. Do **not** redefine this type in
/// other test files — extend or wrap it instead.
///
/// Records calls and exposes inspection helpers so tests can assert
/// byte-level behavior of ``DefaultTerminalAccessService`` and the
/// HTTP transports without spinning a real ghostty surface.
public actor StubSurfaceProvider: SurfaceProvider {
    /// Surfaces returned by ``listSurfaces()`` and matched by
    /// ``resolve(_:)``.
    public var surfaces: [SurfaceInfo] = []
    /// Canned text returned by ``readText(surface:region:)``.
    public var cannedText: String = ""
    /// Optional canned ``CellGrid`` returned by
    /// ``readCells(surface:region:)``. When `nil`, the read throws
    /// ``TerminalAccessError/unsupported(reason:)``.
    public var cannedCells: CellGrid?

    /// Bytes recorded from every ``writeText(surface:bytes:)`` call,
    /// in call order.
    public private(set) var textWrites: [Data] = []
    /// Key events recorded from every ``writeKey(surface:event:)``
    /// call, in call order.
    public private(set) var keyWrites: [KeyEvent] = []
    /// Mouse events recorded from every ``writeMouse(surface:event:)``
    /// call, in call order.
    public private(set) var mouseWrites: [MouseEvent] = []
    /// Focus flags recorded from every ``setFocus(surface:gained:)``
    /// call, in call order.
    public private(set) var focusWrites: [Bool] = []
    /// Counter for any `NSEvent`-synthesis path the stub might take.
    /// This stub never increments it — used in D16 assertions that
    /// verify mouse dispatch goes straight to the provider.
    public private(set) var nsEventBuilds: Int = 0

    /// Creates an empty stub. Populate via ``set(surfaces:)`` and
    /// the other configuration helpers.
    public init() {}

    /// Replaces the in-memory surface list.
    public func set(surfaces: [SurfaceInfo]) { self.surfaces = surfaces }
    /// Replaces the canned text payload.
    public func set(cannedText: String) { self.cannedText = cannedText }
    /// Replaces the canned ``CellGrid``. Pass `nil` to make
    /// ``readCells(surface:region:)`` throw.
    public func set(cannedCells: CellGrid?) { self.cannedCells = cannedCells }

    public func listSurfaces() async throws -> [SurfaceInfo] { surfaces }

    public func resolve(_ h: SurfaceHandle) async throws -> SurfaceInfo? {
        surfaces.first { $0.handle == h || .uuid($0.uuid) == h }
    }

    public func readText(surface: SurfaceInfo, region: ScreenRegion) async throws -> String {
        cannedText
    }

    public func readCells(surface: SurfaceInfo, region: ScreenRegion) async throws -> CellGrid {
        guard let g = cannedCells else {
            throw TerminalAccessError.unsupported(reason: "cells not stubbed")
        }
        return g
    }

    public func writeText(surface: SurfaceInfo, bytes: Data) async throws {
        textWrites.append(bytes)
    }

    public func writeKey(surface: SurfaceInfo, event: KeyEvent) async throws {
        keyWrites.append(event)
    }

    public func writeMouse(surface: SurfaceInfo, event: MouseEvent) async throws {
        mouseWrites.append(event)
    }

    public func setFocus(surface: SurfaceInfo, gained: Bool) async throws {
        focusWrites.append(gained)
    }

    /// Synchronous per Errata E1 — capacity bookkeeping is a fast
    /// in-memory counter. The stub returns a large constant so tests
    /// that exercise fast paths never trip capacity. Tests that need
    /// to assert capacity behavior install an alternate provider
    /// whose ``pendingInputCapacityRemaining(surface:)`` returns a
    /// small constant.
    public nonisolated func pendingInputCapacityRemaining(surface: SurfaceInfo) -> Int {
        1 << 20
    }
}
