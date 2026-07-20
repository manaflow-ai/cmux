import Foundation
import os

/// One app-side surface mirrored into a workspace renderer process.
public final class RendererSurfaceMirror: @unchecked Sendable {
    private struct State {
        var identity: RendererSurfaceIdentity
        var connection: RendererWorkspaceConnection?
        var pendingCommands: [RendererXPCObject] = []
        var pixelWidth: UInt32
        var pixelHeight: UInt32
        var scaleX: Double
        var scaleY: Double
    }

    public nonisolated let outputRelay: RendererProcessOutputRelay
    public nonisolated let events: AsyncStream<RendererXPCObject>

    private let eventContinuation: AsyncStream<RendererXPCObject>.Continuation
    private let state: OSAllocatedUnfairLock<State>

    init(configuration: RendererSurfaceConfiguration, outputRelay: RendererProcessOutputRelay) {
        self.outputRelay = outputRelay
        let pair = AsyncStream<RendererXPCObject>.makeStream(bufferingPolicy: .bufferingNewest(8))
        events = pair.stream
        eventContinuation = pair.continuation
        state = OSAllocatedUnfairLock(initialState: State(
            identity: configuration.identity,
            pixelWidth: configuration.pixelWidth,
            pixelHeight: configuration.pixelHeight,
            scaleX: configuration.scaleX,
            scaleY: configuration.scaleY
        ))
    }

    public var identity: RendererSurfaceIdentity {
        state.withLock { $0.identity }
    }

    /// Sends immediately once connected. A small bounded queue retains control
    /// messages generated during process startup.
    public func send(_ message: RendererXPCObject) {
        let connection: RendererWorkspaceConnection? = state.withLock { state in
            guard let connection = state.connection else {
                state.pendingCommands.append(message)
                if state.pendingCommands.count > 64 {
                    state.pendingCommands.removeFirst(state.pendingCommands.count - 64)
                }
                return nil
            }
            return connection
        }
        connection?.sendImmediately(message)
    }

    public func resize(
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        scaleX: Double,
        scaleY: Double
    ) {
        let destination = state.withLock { state -> (
            RendererWorkspaceConnection?, RendererSurfaceIdentity
        ) in
            state.pixelWidth = pixelWidth
            state.pixelHeight = pixelHeight
            state.scaleX = scaleX
            state.scaleY = scaleY
            return (state.connection, state.identity)
        }
        guard let connection = destination.0 else { return }
        connection.sendImmediately(RendererIPCCommand.resize(
            identity: destination.1,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scaleX: scaleX,
            scaleY: scaleY
        ))
    }

    func configuration(
        basedOn base: RendererSurfaceConfiguration,
        identity: RendererSurfaceIdentity
    ) -> RendererSurfaceConfiguration {
        state.withLock { state in
            RendererSurfaceConfiguration(
                identity: identity,
                pixelWidth: state.pixelWidth,
                pixelHeight: state.pixelHeight,
                scaleX: state.scaleX,
                scaleY: state.scaleY,
                fontSize: base.fontSize,
                workingDirectory: base.workingDirectory,
                command: base.command,
                initialInput: base.initialInput,
                environment: base.environment,
                waitAfterCommand: base.waitAfterCommand,
                context: base.context,
                manualIO: base.manualIO
            )
        }
    }

    func attach(
        connection: RendererWorkspaceConnection,
        identity: RendererSurfaceIdentity
    ) {
        let pending: [RendererXPCObject] = state.withLock { state in
            state.identity = identity
            state.connection = connection
            let pending = state.pendingCommands
            state.pendingCommands.removeAll(keepingCapacity: false)
            return pending
        }
        outputRelay.attach(connection: connection, identity: identity)
        for message in pending {
            connection.sendImmediately(message)
        }
    }

    func detach(identity: RendererSurfaceIdentity) {
        let detached = state.withLock { state -> Bool in
            guard state.identity == identity else { return false }
            state.connection = nil
            return true
        }
        if detached {
            outputRelay.detach(identity: identity)
        }
    }

    func yield(_ event: RendererXPCObject) {
        eventContinuation.yield(event)
    }

    func finish() {
        eventContinuation.finish()
    }
}
