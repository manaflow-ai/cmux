public import Foundation
internal import Darwin
internal import IOSurface
internal import os
internal import RendererMachBridge

public final class RendererSurfacePortReceiver: @unchecked Sendable {
    public enum Error: Swift.Error {
        case registrationFailed(kern_return_t)
        case closed
        case invalidSurface
    }

    public let serviceName: String

    private let receiver: cmux_renderer_port_receiver_t
    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "com.cmux.renderer-surface-port.receiver", qos: .userInteractive)
    private var surfaces: [UInt64: IOSurfaceRef] = [:]
    private var isClosed = false

    public init() throws {
        serviceName = "com.cmux.renderer.surface.\(UUID().uuidString).\(UUID().uuidString)"
        var result = KERN_SUCCESS
        guard let receiver = serviceName.withCString({
            cmux_renderer_port_receiver_create($0, &result)
        }) else {
            throw Error.registrationFailed(result)
        }
        self.receiver = receiver
        queue.async { [weak self] in self?.receiveLoop() }
    }

    deinit {
        close()
        cmux_renderer_port_receiver_destroy(receiver)
    }

    func surface(for token: UInt64) throws -> IOSurfaceRef {
        condition.lock()
        defer { condition.unlock() }
        while surfaces[token] == nil, !isClosed {
            condition.wait()
        }
        guard let surface = surfaces[token] else { throw Error.closed }
        return surface
    }

    public func close() {
        condition.lock()
        guard !isClosed else {
            condition.unlock()
            return
        }
        isClosed = true
        condition.broadcast()
        condition.unlock()
        cmux_renderer_port_receiver_close(receiver)
    }

    private func receiveLoop() {
        while true {
            var token: UInt64 = 0
            var port = mach_port_t(MACH_PORT_NULL)
            let result = cmux_renderer_port_receiver_receive(receiver, &token, &port)
            guard result == KERN_SUCCESS else {
                if result != MACH_RCV_PORT_DIED {
                    Logger(subsystem: "com.cmuxterm.app", category: "renderer-surface-port")
                        .error("Mach receive failed: \(result)")
                }
                break
            }
            defer { mach_port_deallocate(mach_task_self_, port) }
            guard let surface = IOSurfaceLookupFromMachPort(port) else { continue }
            condition.lock()
            surfaces[token] = surface
            condition.broadcast()
            condition.unlock()
        }
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }
}

public final class RendererSurfacePortSender: @unchecked Sendable {
    public enum Error: Swift.Error {
        case lookupFailed(kern_return_t)
        case sendFailed(kern_return_t)
    }

    private struct State {
        var tokensBySurfaceID: [IOSurfaceID: UInt64] = [:]
        var nextToken: UInt64 = 1
    }

    private let sender: cmux_renderer_port_sender_t
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(serviceName: String) throws {
        var result = KERN_SUCCESS
        guard let sender = serviceName.withCString({
            cmux_renderer_port_sender_create($0, &result)
        }) else {
            throw Error.lookupFailed(result)
        }
        self.sender = sender
    }

    deinit {
        cmux_renderer_port_sender_destroy(sender)
    }

    func token(for surface: IOSurfaceRef) throws -> UInt64 {
        let surfaceID = IOSurfaceGetID(surface)
        if let existing = state.withLock({ $0.tokensBySurfaceID[surfaceID] }) {
            return existing
        }
        let tokenAndNeedsSend = state.withLock { state -> (UInt64, Bool) in
            if let existing = state.tokensBySurfaceID[surfaceID] {
                return (existing, false)
            }
            let token = state.nextToken
            state.nextToken &+= 1
            state.tokensBySurfaceID[surfaceID] = token
            return (token, true)
        }
        let (token, needsSend) = tokenAndNeedsSend
        guard needsSend else { return token }
        let port = IOSurfaceCreateMachPort(surface)
        let result = cmux_renderer_port_sender_send(sender, token, port)
        guard result == KERN_SUCCESS else {
            state.withLock { state in
                if state.tokensBySurfaceID[surfaceID] == token {
                    state.tokensBySurfaceID.removeValue(forKey: surfaceID)
                }
            }
            throw Error.sendFailed(result)
        }
        return token
    }
}
