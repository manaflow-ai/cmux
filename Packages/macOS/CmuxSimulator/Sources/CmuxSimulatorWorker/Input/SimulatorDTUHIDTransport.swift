import CmuxSimulator
import Darwin
import Foundation
import ObjectiveC.runtime
@preconcurrency import XPC

/// Xcode 27's `dtuhidd` transport, isolated to the worker.
///
/// Adapted from idb's `FBSimulatorDTUHIDTransport` and wire models (MIT,
/// Meta Platforms). Messages use plain XPC dictionaries so cmux does not need
/// private framework headers or an additional encoder dependency.
@MainActor
final class SimulatorDTUHIDTransport {
    private static let serviceName = "com.apple.coredevice.feature.remote.hid.digitizer"

    private typealias EndpointFromMachPortFunction = @convention(c) (
        mach_port_t,
        UInt64,
        UInt64
    ) -> xpc_object_t?
    private typealias ConnectionFromEndpointFunction = @convention(c) (
        xpc_object_t
    ) -> xpc_connection_t?
    private typealias EnableSimulatorToHostFunction = @convention(c) (
        xpc_connection_t
    ) -> Void

    private let connectionLifetime: SimulatorDTUHIDConnectionLifetime
    private let connectionState: SimulatorDTUHIDConnectionState

    init(device: NSObject) throws {
        guard let processHandle = dlopen(nil, RTLD_NOW),
              let endpointSymbol = dlsym(processHandle, "xpc_endpoint_create_mach_port_4sim"),
              let connectionSymbol = dlsym(processHandle, "xpc_connection_create_from_endpoint"),
              let enableSymbol = dlsym(processHandle, "xpc_connection_enable_sim2host_4sim")
        else {
            throw SimulatorWorkerFailure.inputUnavailable(
                "The active runtime does not expose Xcode 27's DTUHID XPC symbols."
            )
        }
        let endpointFromMachPort = unsafeBitCast(
            endpointSymbol,
            to: EndpointFromMachPortFunction.self
        )
        let connectionFromEndpoint = unsafeBitCast(
            connectionSymbol,
            to: ConnectionFromEndpointFunction.self
        )
        let enableSimulatorToHost = unsafeBitCast(
            enableSymbol,
            to: EnableSimulatorToHostFunction.self
        )

        let servicePort = try simulatorDTUHIDServicePort(
            on: device,
            serviceName: Self.serviceName
        )
        guard let endpoint = endpointFromMachPort(servicePort, 0, 0),
              let connection = connectionFromEndpoint(endpoint)
        else {
            throw SimulatorWorkerFailure.inputUnavailable(
                "The Simulator DTUHID service refused its host XPC endpoint."
            )
        }
        enableSimulatorToHost(connection)
        let connectionState = SimulatorDTUHIDConnectionState()
        xpc_connection_set_event_handler(connection) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                Task { @MainActor in
                    connectionState.markUnavailable()
                }
            }
        }
        xpc_connection_resume(connection)
        connectionLifetime = SimulatorDTUHIDConnectionLifetime(connection: connection)
        self.connectionState = connectionState
    }

    func send(_ event: SimulatorPointerEvent) -> Bool {
        let eventType: UInt64 = switch event.phase {
        case .began: 0
        case .moved: 1
        case .ended, .cancelled: 2
        }
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(payload, "pointOne", simulatorDTUHIDPoint(event.primary))
        if let secondary = event.secondary {
            xpc_dictionary_set_value(payload, "pointTwo", simulatorDTUHIDPoint(secondary))
        }
        xpc_dictionary_set_uint64(payload, "eventType", eventType)
        xpc_dictionary_set_uint64(payload, "edge", UInt64(event.edge.rawValue))
        xpc_dictionary_set_uint64(payload, "target", 0)
        return send(messageType: "IndigoDigitizerEvent", payload: payload)
    }

    func send(_ event: SimulatorKeyEvent) -> Bool {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", UInt64(event.usage))
        xpc_dictionary_set_uint64(payload, "state", event.phase == .down ? 1 : 2)
        return send(messageType: "IndigoKeyboardButtonEvent", payload: payload)
    }

    func sendButton(page: UInt32, usage: UInt32, down: Bool) -> Bool {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usagePage", UInt64(page))
        xpc_dictionary_set_uint64(payload, "usageCode", UInt64(usage))
        xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2)
        return send(messageType: "IndigoButtonEvent", payload: payload)
    }

    /// Waits until libxpc has drained all earlier sends from the local
    /// connection. dtuhidd does not acknowledge guest receipt.
    func drainLocalTransmission() async -> Bool {
        let waiter = SimulatorDTUHIDBarrierWaiter()
        let connection = connectionLifetime.connection
        let state = connectionState
        return await waiter.wait { completion in
            xpc_connection_send_barrier(connection) {
                Task { @MainActor in
                    completion(state.isAvailable)
                }
            }
        }
    }

    private func send(messageType: String, payload: xpc_object_t) -> Bool {
        guard connectionState.isAvailable else { return false }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", messageType)
        xpc_dictionary_set_bool(message, "isBarrier", false)
        xpc_dictionary_set_string(message, "featureIdentifier", Self.serviceName)
        xpc_dictionary_set_value(message, "payload", payload)
        xpc_connection_send_message(connectionLifetime.connection, message)
        return connectionState.isAvailable
    }
}

private func simulatorDTUHIDPoint(_ point: SimulatorPoint) -> xpc_object_t {
    let value = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_double(value, "x", point.x)
    xpc_dictionary_set_double(value, "y", point.y)
    return value
}

private func simulatorDTUHIDServicePort(
    on device: NSObject,
    serviceName: String
) throws -> mach_port_t {
    let selector = NSSelectorFromString("lookup:error:")
    guard device.responds(to: selector),
          let implementation = class_getMethodImplementation(type(of: device), selector)
    else {
        throw SimulatorWorkerFailure.inputUnavailable(
            "SimDevice cannot look up the DTUHID service."
        )
    }
    typealias Function = @convention(c) (
        AnyObject,
        Selector,
        NSString,
        AutoreleasingUnsafeMutablePointer<NSError?>
    ) -> mach_port_t
    var error: NSError?
    let port = unsafeBitCast(implementation, to: Function.self)(
        device,
        selector,
        serviceName as NSString,
        &error
    )
    guard port != mach_port_t(MACH_PORT_NULL) else {
        throw SimulatorWorkerFailure.inputUnavailable(
            error?.localizedDescription ?? "The Simulator DTUHID service is not running."
        )
    }
    return port
}
