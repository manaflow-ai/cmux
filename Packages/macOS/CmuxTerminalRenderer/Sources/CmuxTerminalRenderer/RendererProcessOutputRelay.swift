import Foundation
import os

/// Relays PTY output to a renderer worker without scheduling one task per read.
///
/// Before the worker connects, a bounded byte buffer preserves startup output.
/// Once attached, the serialized Ghostty read callback sends one XPC message
/// directly for each chunk. The lock only protects the connection handoff and
/// bounded startup buffer; XPC performs the actual byte copy after the lock is
/// released.
public final class RendererProcessOutputRelay: @unchecked Sendable {
    /// The lock executes its closure synchronously and never retains this
    /// borrowed callback buffer. Swift cannot express that lifetime relation,
    /// so the unchecked wrapper is kept private to this method's implementation.
    private struct SynchronousBytes: @unchecked Sendable {
        let value: UnsafeBufferPointer<UInt8>
    }

    private struct State {
        var connection: RendererWorkspaceConnection?
        var identity: RendererSurfaceIdentity?
        var pending = Data()
        var discardedPrefixByteCount = 0
    }

    public static let defaultPendingByteLimit = 8 * 1_024 * 1_024

    private let pendingByteLimit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(pendingByteLimit: Int = defaultPendingByteLimit) {
        self.pendingByteLimit = max(1, pendingByteLimit)
    }

    /// Appends bytes from Ghostty's serialized PTY callback.
    public func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }
        let synchronousBytes = SynchronousBytes(value: bytes)
        state.withLock { state in
            if let connection = state.connection, let identity = state.identity {
                connection.sendProcessOutputImmediately(
                    identity: identity,
                    bytes: synchronousBytes.value
                )
                return
            }
            if let baseAddress = synchronousBytes.value.baseAddress {
                state.pending.append(baseAddress, count: synchronousBytes.value.count)
            }
            if state.pending.count > pendingByteLimit {
                let overflow = state.pending.count - pendingByteLimit
                state.pending.removeFirst(overflow)
                state.discardedPrefixByteCount += overflow
            }
        }
    }

    /// Attaches the live worker and flushes buffered startup output in order.
    public func attach(
        connection: RendererWorkspaceConnection,
        identity: RendererSurfaceIdentity
    ) {
        state.withLock { state in
            // Flush before publishing the live destination. An append racing
            // attach blocks on this lock, then sends after the buffered prefix.
            if !state.pending.isEmpty {
                state.pending.withUnsafeBytes { rawBuffer in
                    connection.sendProcessOutputImmediately(
                        identity: identity,
                        bytes: rawBuffer.bindMemory(to: UInt8.self)
                    )
                }
                state.pending.removeAll(keepingCapacity: false)
            }
            state.connection = connection
            state.identity = identity
        }
    }

    /// Detaches only the matching worker generation, preserving subsequent
    /// output in the bounded startup buffer for a replacement worker.
    public func detach(identity: RendererSurfaceIdentity) {
        state.withLock { state in
            guard state.identity == identity else { return }
            state.connection = nil
            state.identity = nil
        }
    }

    public var discardedPrefixByteCount: Int {
        state.withLock { $0.discardedPrefixByteCount }
    }
}

public extension RendererWorkspaceConnection {
    /// Builds and sends the PTY-output message directly on the calling thread.
    nonisolated func sendProcessOutputImmediately(
        identity: RendererSurfaceIdentity,
        bytes: UnsafeBufferPointer<UInt8>
    ) {
        let message = RendererIPCCommand.surface(operation: .processOutput, identity: identity)
        xpc_dictionary_set_data(
            message,
            RendererIPCKey.data,
            bytes.baseAddress,
            bytes.count
        )
        sendImmediately(RendererXPCObject(message))
    }
}
