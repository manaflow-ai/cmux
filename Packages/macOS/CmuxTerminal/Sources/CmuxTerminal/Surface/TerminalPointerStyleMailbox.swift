public import Foundation
internal import os

/// Reduces synchronous callbacks before coalescing notifications to a UI consumer.
///
/// One complete state and one pending wakeup bound storage independently of
/// callback volume. No delta is dropped: the reducer runs before `yield`.
/// The AppKit owner reads ``snapshot`` and rejects already-applied revisions.
///
/// The short lock is intentional: Ghostty's synchronous callback cannot await
/// an actor without either buffering deltas or spawning an unbounded task queue.
/// Only fixed-size value reduction runs inside it, never AppKit, I/O, or await.
public final class TerminalPointerStyleMailbox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: TerminalPointerStyleSnapshot())
    private let continuation: AsyncStream<Void>.Continuation

    /// Coalesced wakeups for the single main-actor consumer; read ``snapshot`` on each.
    public let updates: AsyncStream<Void>

    /// Creates an empty mailbox for one terminal view.
    public init() {
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = channel.stream
        continuation = channel.continuation
    }

    deinit { continuation.finish() }

    /// Latest complete state, copied under the callback serialization boundary.
    public var snapshot: TerminalPointerStyleSnapshot { state.withLock { $0 } }

    /// Registers a runtime before its constructor can emit synchronous callbacks.
    /// - Parameters:
    ///   - lifetimeId: New native runtime identity.
    ///   - surfaceId: Logical terminal owner.
    /// - Returns: The generation to embed in callback userdata.
    @discardableResult
    public func activate(lifetimeId: UUID, surfaceId: UUID) -> UInt64 {
        let generation = state.withLock { state in
            state.runtimeGeneration &+= 1
            state.surfaceId = surfaceId
            state.intent.apply(.runtimeActivated(lifetimeId))
            state.revision &+= 1
            return state.runtimeGeneration
        }
        continuation.yield(())
        return generation
    }

    /// Applies a view-owned focus, hover, or lifecycle input synchronously.
    /// - Parameters:
    ///   - event: Input to the single pointer reducer.
    ///   - focusGeneration: Optional captured epoch for a delayed shape/hover input.
    /// - Returns: The resulting snapshot, or nil for a stale focus epoch.
    @discardableResult
    public func apply(
        _ event: TerminalPointerStyleEvent,
        focusGeneration: UInt64? = nil
    ) -> TerminalPointerStyleSnapshot? {
        let result = state.withLock { state -> TerminalPointerStyleSnapshot? in
            if let focusGeneration, focusGeneration != state.focusGeneration { return nil }
            if case .focusChanged(let focused) = event, focused != state.intent.focused {
                state.focusGeneration &+= 1
            }
            state.intent.apply(event)
            state.revision &+= 1
            return state
        }
        if result != nil { continuation.yield(()) }
        return result
    }

    /// Reduces a Ghostty callback only while its native owner is still active.
    /// - Parameters:
    ///   - event: Shape, link-hover, reset, or end input from Ghostty.
    ///   - surfaceId: Logical owner captured by the callback.
    ///   - lifetimeId: Native owner captured by the callback.
    ///   - generation: Generation returned by ``activate(lifetimeId:surfaceId:)``.
    /// - Returns: Whether the callback belonged to the current native lifetime.
    @discardableResult
    public func submit(
        _ event: TerminalPointerStyleEvent,
        surfaceId: UUID,
        lifetimeId: UUID,
        generation: UInt64
    ) -> Bool {
        let accepted = state.withLock { state in
            guard state.surfaceId == surfaceId,
                  state.runtimeGeneration == generation,
                  state.intent.activeRuntimeLifetimeId == lifetimeId else { return false }
            switch event {
            case .ghosttyShape(_, let id), .ghosttyLinkHoverChanged(_, let id), .runtimeReset(let id):
                guard id == lifetimeId else { return false }
            case .runtimeEnded(let id):
                guard id == lifetimeId else { return false }
            case .runtimeActivated, .focusChanged, .cmuxLinkHoverChanged:
                return false
            }
            state.intent.apply(event)
            state.revision &+= 1
            return true
        }
        if accepted { continuation.yield(()) }
        return accepted
    }

    /// Ends observation when the owning native view is removed.
    public func finish() { continuation.finish() }
}
