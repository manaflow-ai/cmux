import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

enum SkyLightEventPost {
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias SetIntFieldFn = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias FactoryMsgSendFn = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutableRawPointer,
        Int32,
        UInt32
    ) -> AnyObject?

    private struct Resolved: @unchecked Sendable {
        let postToPid: PostToPidFn
        let setAuthMessage: SetAuthMessageFn
        let messageFactory: FactoryMsgSendFn
        let messageClass: AnyClass
        let messageSelector: Selector
    }

    private static let resolved: Resolved? = {
        openSkyLight()

        guard
            let postToPid = resolve("SLEventPostToPid", as: PostToPidFn.self),
            let setAuthMessage = resolve("SLEventSetAuthenticationMessage", as: SetAuthMessageFn.self),
            let messageFactory = resolve("objc_msgSend", as: FactoryMsgSendFn.self),
            let messageClass = NSClassFromString("SLSEventAuthenticationMessage")
        else {
            return nil
        }

        return Resolved(
            postToPid: postToPid,
            setAuthMessage: setAuthMessage,
            messageFactory: messageFactory,
            messageClass: messageClass,
            messageSelector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
    }()

    private static let setWindowLocationFn: SetWindowLocationFn? = {
        openSkyLight()
        return resolve("CGEventSetWindowLocation", as: SetWindowLocationFn.self)
    }()

    private static let setIntFieldFn: SetIntFieldFn? = {
        openSkyLight()
        return resolve("SLEventSetIntegerValueField", as: SetIntFieldFn.self)
    }()

    @discardableResult
    static func postToPid(_ pid: pid_t, event: CGEvent, attachAuthMessage: Bool = true) -> Bool {
        guard let resolved else {
            return false
        }

        if attachAuthMessage {
            guard
                let record = extractEventRecord(from: event),
                let message = resolved.messageFactory(
                    resolved.messageClass as AnyObject,
                    resolved.messageSelector,
                    record,
                    pid,
                    0
                )
            else {
                return false
            }

            resolved.setAuthMessage(event, message)
        }

        resolved.postToPid(pid, event)
        return true
    }

    @discardableResult
    static func setWindowLocation(_ event: CGEvent, _ point: CGPoint) -> Bool {
        guard let setWindowLocationFn else {
            return false
        }
        setWindowLocationFn(event, point)
        return true
    }

    @discardableResult
    static func setIntegerField(_ event: CGEvent, field: UInt32, value: Int64) -> Bool {
        guard let setIntFieldFn else {
            return false
        }
        setIntFieldFn(event, field, value)
        return true
    }

    private static func openSkyLight() {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }

    private static func resolve<T>(_ name: String, as _: T.Type) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let record = slot.pointee {
                return record
            }
        }
        return nil
    }
}
