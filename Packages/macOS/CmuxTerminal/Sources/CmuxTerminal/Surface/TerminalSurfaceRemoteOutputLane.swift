internal import Dispatch
internal import Foundation
internal import GhosttyKit
internal import os

/// A native size snapshot copied while the manual surface lane owns the
/// Ghostty pointer. C structs from Ghostty must not cross the Swift actor
/// boundary; this value is the stable, Sendable representation used by the
/// main-actor layout code.
struct TerminalSurfaceManualGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

struct TerminalSurfaceManualGeometrySnapshot: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let widthPixels: UInt32
    let heightPixels: UInt32
    let cellWidthPixels: UInt32
    let cellHeightPixels: UInt32
    let xScale: Double
    let yScale: Double

    var grid: TerminalSurfaceManualGrid {
        TerminalSurfaceManualGrid(columns: columns, rows: rows)
    }
}

/// One ordered native geometry mutation for a manual-I/O surface.
/// `assignedGrid` is authoritative when present. The lane resolves its exact
/// pixel dimensions with Ghostty instead of repeating font/padding arithmetic
/// in Swift, which prevents drift after a scale or font change.
struct TerminalSurfaceManualGeometryRequest: Sendable {
    let widthPixels: UInt32
    let heightPixels: UInt32
    let xScale: Double
    let yScale: Double
    let applyScale: Bool
    let deferScaleOnIncrease: Bool
    let applySize: Bool
    let assignedGrid: TerminalSurfaceManualGrid?
    let suppressReflow: Bool
    let coalescePixelOnlyResize: Bool
    let hasAppliedPixelSize: Bool
    let sequence: UInt64
    let runtimeGeneration: UInt64
    let caller: String
}

/// Result copied from the manual surface lane after one geometry mutation.
struct TerminalSurfaceManualGeometryResult: Sendable {
    let snapshot: TerminalSurfaceManualGeometrySnapshot
    let scaleChanged: Bool
    let sizeChanged: Bool
    let assignedGridApplied: Bool
    let sequence: UInt64
    let runtimeGeneration: UInt64
    let caller: String
}

/// Serializes manually injected terminal output away from the main actor.
///
/// Ghostty's output parser takes the renderer-state mutex synchronously. Remote
/// tmux notifications arrive on the main actor, so invoking that parser inline
/// can park the UI indefinitely while a renderer or a stale native owner holds
/// the mutex. Each runtime generation gets its own lane; closing a generation
/// rejects new work while preserving FIFO order for already-admitted work, and
/// teardown drains that work before freeing the native surface. The unchecked
/// sendability is safe because the queue and lifecycle gate are the only
/// mutable state; the borrowed surface pointer is used only by queued work and
/// is drained before its owner frees it.
final class TerminalSurfaceRemoteOutputLane: @unchecked Sendable {
    private let queue: DispatchQueue
    // The synchronous gate is required because enqueueTextInput and close can
    // race from the main actor and teardown/lane threads; an actor hop could
    // accept work after retirement. Only one Boolean read/write is protected,
    // and the lock is never held across a native call or suspension point.
    private let isOpen = OSAllocatedUnfairLock(initialState: true)

    init(surfaceID: UUID, generation: UInt64) {
        queue = DispatchQueue(
            label: "com.cmux.terminal-surface.remote-output.\(surfaceID.uuidString).\(generation)",
            qos: .userInitiated
        )
    }

    /// Enqueues one ordered output batch and its refresh signal.
    func enqueue(_ data: Data, to surface: ghostty_surface_t) {
        guard !data.isEmpty else { return }
        // Raw pointers are represented as bits across the Sendable queue
        // boundary; the lane fence owns the native lifetime until this work
        // has completed.
        let surfaceBits = UInt(bitPattern: surface)
        isOpen.withLock { isOpen in
            guard isOpen else { return }
            // Admission and queue submission share the gate with `close()`,
            // so every accepted operation is ahead of the drain fence.
            queue.async { [surfaceBits] in
                guard let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits) else {
                    return
                }
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                        return
                    }
                    ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
                }
                ghostty_surface_refresh(surface)
            }
        }
    }

    /// Enqueues manual text input behind earlier remote output.
    @discardableResult
    func enqueueTextInput(_ data: Data, to surface: ghostty_surface_t) -> Bool {
        guard !data.isEmpty else { return false }
        let surfaceBits = UInt(bitPattern: surface)
        return isOpen.withLock { isOpen in
            guard isOpen else { return false }
            // Keep queue submission inside the same admission critical
            // section as `close()`; the native call itself remains outside it.
            queue.async { [surfaceBits] in
                guard let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits) else {
                    return
                }
                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                        return
                    }
                    ghostty_surface_text_input(surface, baseAddress, UInt(rawBuffer.count))
                }
            }
            return true
        }
    }

    /// Enqueues a refresh behind all earlier native work. A refresh is kept on
    /// the same lane as output and geometry so a draw cannot observe a
    /// half-applied manual resize.
    @discardableResult
    func enqueueRefresh(to surface: ghostty_surface_t) -> Bool {
        let surfaceBits = UInt(bitPattern: surface)
        return isOpen.withLock { isOpen in
            guard isOpen else { return false }
            queue.async { [surfaceBits] in
                guard let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits) else {
                    return
                }
                ghostty_surface_refresh(surface)
            }
            return true
        }
    }

    /// Enqueues a scale/size mutation behind all earlier output and input.
    /// Every Ghostty call, including the readback, runs on this same serial
    /// lane. The completion only carries copied values back to the main actor.
    @discardableResult
    func enqueueGeometry(
        _ request: TerminalSurfaceManualGeometryRequest,
        to surface: ghostty_surface_t,
        completion: @escaping @MainActor @Sendable (TerminalSurfaceManualGeometryResult) -> Void
    ) -> Bool {
        let surfaceBits = UInt(bitPattern: surface)
        return isOpen.withLock { isOpen in
            guard isOpen else { return false }
            queue.async { [surfaceBits, request, completion] in
                guard let surface = UnsafeMutableRawPointer(bitPattern: surfaceBits) else {
                    return
                }

                let before = ghostty_surface_size(surface)
                let scaleChanged = request.applyScale
                let deferScale = request.deferScaleOnIncrease && scaleChanged

                func applyScaleIfNeeded() {
                    guard request.applyScale else { return }
                    ghostty_surface_set_content_scale(
                        surface,
                        request.xScale,
                        request.yScale
                    )
                }

                func process(_ data: Data) {
                    guard !data.isEmpty else { return }
                    data.withUnsafeBytes { rawBuffer in
                        guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                            return
                        }
                        ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
                    }
                }

                if !deferScale {
                    applyScaleIfNeeded()
                }

                var assignedGridApplied = false
                if request.applySize, request.widthPixels > 0, request.heightPixels > 0 {
                    if request.suppressReflow {
                        process(Self.decawmDisableSequence)
                    }

                    if let assignedGrid = request.assignedGrid,
                       assignedGrid.columns > 0,
                       assignedGrid.rows > 0,
                       assignedGrid.columns <= Int(UInt16.max),
                       assignedGrid.rows <= Int(UInt16.max) {
                        assignedGridApplied = ghostty_surface_set_grid_size(
                            surface,
                            UInt16(assignedGrid.columns),
                            UInt16(assignedGrid.rows),
                            nil
                        )
                        // A surface can be created before its font metrics are
                        // ready. Keep a visible bootstrap size in that case;
                        // the next layout operation retries the authoritative
                        // grid once metrics exist.
                        if !assignedGridApplied {
                            ghostty_surface_set_size(
                                surface,
                                request.widthPixels,
                                request.heightPixels
                            )
                        }
                    } else {
                        let shouldApply = !request.coalescePixelOnlyResize
                            || request.applyScale
                            || TerminalSurface.shouldApplySurfacePixelSizeChange(
                                currentColumns: UInt32(before.columns),
                                currentRows: UInt32(before.rows),
                                currentWidthPx: before.width_px,
                                currentHeightPx: before.height_px,
                                currentCellWidthPx: before.cell_width_px,
                                currentCellHeightPx: before.cell_height_px,
                                targetWidthPx: request.widthPixels,
                                targetHeightPx: request.heightPixels,
                                coalescePixelOnlyResize: true,
                                hasAppliedPixelSize: request.hasAppliedPixelSize
                            )
                        if shouldApply {
                            ghostty_surface_set_size(
                                surface,
                                request.widthPixels,
                                request.heightPixels
                            )
                        }
                    }

                    if request.suppressReflow {
                        process(Self.decawmEnableSequence)
                    }
                    ghostty_surface_refresh(surface)
                }

                if deferScale {
                    applyScaleIfNeeded()
                }

                let after = ghostty_surface_size(surface)
                let snapshot = TerminalSurfaceManualGeometrySnapshot(
                    columns: Int(after.columns),
                    rows: Int(after.rows),
                    widthPixels: after.width_px,
                    heightPixels: after.height_px,
                    cellWidthPixels: after.cell_width_px,
                    cellHeightPixels: after.cell_height_px,
                    xScale: request.xScale,
                    yScale: request.yScale
                )
                let result = TerminalSurfaceManualGeometryResult(
                    snapshot: snapshot,
                    scaleChanged: scaleChanged,
                    sizeChanged: before.width_px != after.width_px
                        || before.height_px != after.height_px,
                    assignedGridApplied: assignedGridApplied,
                    sequence: request.sequence,
                    runtimeGeneration: request.runtimeGeneration,
                    caller: request.caller
                )
                Task { @MainActor in
                    completion(result)
                }
            }
            return true
        }
    }

    /// Stops admission of new work for this runtime generation.
    ///
    /// Operations accepted before this call remain in FIFO order and are
    /// drained before native teardown; later submissions are rejected.
    func close() {
        isOpen.withLock { $0 = false }
    }

    /// Closes the lane and asynchronously waits for its FIFO fence.
    ///
    /// Awaiting this method suspends the caller instead of blocking a thread.
    /// If Ghostty is wedged inside an already-running operation, only the lane
    /// worker remains blocked until that native call returns.
    func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Keep close and fence submission in one critical section. Every
            // operation admitted before the state flip is already queued ahead
            // of this fence, and no operation can be admitted in between.
            isOpen.withLock { isOpen in
                isOpen = false
                queue.async {
                    continuation.resume()
                }
            }
        }
    }

#if DEBUG
    /// Synchronously fences test-only direct-free helpers after queued work is done.
    /// This is unavailable in release builds; production teardown uses
    /// ``drain()`` so no app worker waits on the lane.
    func drainSynchronouslyForTesting() {
        close()
        queue.sync {}
    }
#endif

    private static let decawmDisableSequence = Data("\u{1b}[?7l".utf8)
    private static let decawmEnableSequence = Data("\u{1b}[?7h".utf8)
}

extension TerminalSurface {
    /// Retires the current output lane and opens one for the next runtime generation.
    @MainActor
    func retireRemoteOutputLane() -> TerminalSurfaceRemoteOutputLane {
        let retired = remoteOutputLane
        retired.close()
        remoteOutputLaneGeneration &+= 1
        remoteOutputLane = TerminalSurfaceRemoteOutputLane(
            surfaceID: id,
            generation: remoteOutputLaneGeneration
        )
        return retired
    }
}
