import Darwin
import Foundation
import OwlBrowserCore

final class MachPlatformChannel {
    private static let nullPort = mach_port_t(0)

    private var localSendRight: mach_port_t
    private var remoteReceiveRight: mach_port_t

    init() throws {
        var receiveRight: mach_port_t = Self.nullPort
        var result = mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &receiveRight)
        guard result == KERN_SUCCESS else {
            throw OwlBrowserError.launch("mach_port_allocate failed with result \(result)")
        }

        var limits = mach_port_limits_t(mpl_qlimit: mach_port_msgcount_t(MACH_PORT_QLIMIT_LARGE))
        let limitsCount = mach_msg_type_number_t(MemoryLayout<mach_port_limits_t>.size / MemoryLayout<natural_t>.size)
        result = withUnsafePointer(to: &limits) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(limitsCount)) { rebound in
                mach_port_set_attributes(
                    mach_task_self_,
                    receiveRight,
                    mach_port_flavor_t(MACH_PORT_LIMITS_INFO),
                    UnsafeMutablePointer(mutating: rebound),
                    limitsCount
                )
            }
        }
        guard result == KERN_SUCCESS else {
            Self.dropReceiveRight(receiveRight)
            throw OwlBrowserError.launch("mach_port_set_attributes failed with result \(result)")
        }

        result = mach_port_insert_right(
            mach_task_self_,
            receiveRight,
            receiveRight,
            mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)
        )
        guard result == KERN_SUCCESS else {
            Self.dropReceiveRight(receiveRight)
            throw OwlBrowserError.launch("mach_port_insert_right failed with result \(result)")
        }

        self.localSendRight = receiveRight
        self.remoteReceiveRight = receiveRight
    }

    func takeLocalSendRight() -> mach_port_t {
        let port = localSendRight
        localSendRight = Self.nullPort
        return port
    }

    func takeRemoteReceiveRight() -> mach_port_t {
        let port = remoteReceiveRight
        remoteReceiveRight = Self.nullPort
        return port
    }

    func destroy() {
        if localSendRight != Self.nullPort {
            mach_port_mod_refs(
                mach_task_self_,
                localSendRight,
                mach_port_right_t(MACH_PORT_RIGHT_SEND),
                -1
            )
            localSendRight = Self.nullPort
        }
        if remoteReceiveRight != Self.nullPort {
            Self.dropReceiveRight(remoteReceiveRight)
            remoteReceiveRight = Self.nullPort
        }
    }

    deinit {
        destroy()
    }

    private static func dropReceiveRight(_ port: mach_port_t) {
        mach_port_mod_refs(
            mach_task_self_,
            port,
            mach_port_right_t(MACH_PORT_RIGHT_RECEIVE),
            -1
        )
    }
}
