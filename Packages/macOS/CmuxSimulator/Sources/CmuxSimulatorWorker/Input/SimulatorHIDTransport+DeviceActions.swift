import CmuxSimulator
import Darwin.Mach
import Foundation
import ObjectiveC.runtime

extension SimulatorHIDTransport {
    @discardableResult
    func rotate(_ orientation: SimulatorOrientation) -> Bool {
        guard let device else { return false }
        let value = SimulatorNativeOrientationCodec.purpleWorkspaceRawValue(for: orientation)
        return sendOrientation(value, to: device)
    }

    @discardableResult
    func simulateMemoryWarning() -> Bool {
        guard let device else { return false }
        let selector = NSSelectorFromString("simulateMemoryWarning")
        guard device.responds(to: selector) else { return false }
        device.perform(selector)
        return true
    }

    @discardableResult
    func setCoreAnimationDiagnostic(_ diagnostic: SimulatorCADiagnostic, enabled: Bool) -> Bool {
        guard let device else { return false }
        let selector = NSSelectorFromString("setCADebugOption:enabled:")
        guard device.responds(to: selector),
              let implementation = class_getMethodImplementation(type(of: device), selector)
        else {
            return false
        }
        let name: String = switch diagnostic {
        case .blended: "debug_color_blended"
        case .copies: "debug_color_copies"
        case .misaligned: "debug_color_misaligned"
        case .offscreen: "debug_color_offscreen"
        case .slowAnimations: "debug_slow_animations"
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            ObjCBool
        ) -> ObjCBool
        return unsafeBitCast(implementation, to: Function.self)(
            device,
            selector,
            name as NSString,
            ObjCBool(enabled)
        ).boolValue
    }

    private func sendOrientation(_ orientation: UInt32, to device: NSObject) -> Bool {
        let lookupSelector = NSSelectorFromString("lookup:error:")
        guard device.responds(to: lookupSelector),
              let implementation = class_getMethodImplementation(type(of: device), lookupSelector)
        else {
            return false
        }
        typealias LookupFunction = @convention(c) (
            AnyObject,
            Selector,
            NSString,
            AutoreleasingUnsafeMutablePointer<NSError?>
        ) -> mach_port_t
        var error: NSError?
        let port = unsafeBitCast(implementation, to: LookupFunction.self)(
            device,
            lookupSelector,
            "PurpleWorkspacePort" as NSString,
            &error
        )
        guard port != MACH_PORT_NULL else { return false }

        // Wire format adapted from idb's SimulatorApp/GSEvent.h (MIT) and
        // Baguette's PurpleEventOrientation.swift (Apache-2.0).
        var buffer = [UInt8](repeating: 0, count: 112)
        return buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            let header = baseAddress.assumingMemoryBound(to: mach_msg_header_t.self)
            header.pointee.msgh_bits = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
            header.pointee.msgh_size = 108
            header.pointee.msgh_remote_port = port
            header.pointee.msgh_local_port = mach_port_t(MACH_PORT_NULL)
            header.pointee.msgh_voucher_port = mach_port_t(MACH_PORT_NULL)
            header.pointee.msgh_id = 0x7B
            baseAddress.storeBytes(of: UInt32(50 | 0x20000), toByteOffset: 0x18, as: UInt32.self)
            baseAddress.storeBytes(of: UInt32(4), toByteOffset: 0x48, as: UInt32.self)
            baseAddress.storeBytes(of: orientation, toByteOffset: 0x4C, as: UInt32.self)
            return mach_msg(
                header,
                MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                header.pointee.msgh_size,
                0,
                mach_port_t(MACH_PORT_NULL),
                2_000,
                mach_port_t(MACH_PORT_NULL)
            ) == KERN_SUCCESS
        }
    }
}
