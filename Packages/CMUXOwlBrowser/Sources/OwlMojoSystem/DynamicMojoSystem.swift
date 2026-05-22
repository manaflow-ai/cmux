import Darwin
import Foundation

public struct MojoSystemError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let result: UInt32?

    public init(_ message: String, result: UInt32? = nil) {
        self.message = message
        self.result = result
    }

    public var description: String {
        message
    }

    public var isFailedPrecondition: Bool {
        result == DynamicMojoSystem.mojoResultFailedPrecondition
    }
}

public struct MojoHandle: Equatable, Hashable, Sendable {
    public static let invalid = MojoHandle(rawValue: 0)

    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public var isValid: Bool {
        rawValue != 0
    }
}

public struct MojoMessagePipe: Equatable, Sendable {
    public let endpoint0: MojoHandle
    public let endpoint1: MojoHandle

    public init(endpoint0: MojoHandle, endpoint1: MojoHandle) {
        self.endpoint0 = endpoint0
        self.endpoint1 = endpoint1
    }
}

public protocol MojoMessagePipeCreating: AnyObject {
    func createMessagePipe() throws -> MojoMessagePipe
    func close(_ handle: MojoHandle) throws
}

public protocol MojoInvitationSending: AnyObject {
    func createInvitation() throws -> MojoHandle
    func attachMessagePipe(toInvitation invitation: MojoHandle, name: UInt64) throws -> MojoHandle
    func sendInvitation(_ invitation: MojoHandle, toProcessID processID: pid_t, machSendRight: mach_port_t) throws
}

public protocol MojoMessageWriting: AnyObject {
    func writeMessage(pipe: MojoHandle, data: Data, handles: [MojoHandle]) throws
}

public protocol MojoMessageReading: AnyObject {
    func readMessage(pipe: MojoHandle, timeout: TimeInterval) throws -> Data
}

public protocol MojoMessagePeeking: MojoMessageReading {
    func readMessageIfAvailable(pipe: MojoHandle) throws -> Data?
}

public final class DynamicMojoSystem: MojoMessagePipeCreating, MojoInvitationSending, MojoMessageWriting, MojoMessagePeeking {
    private typealias MojoCreateMessagePipeFunction = @convention(c) (
        UnsafeRawPointer?,
        UnsafeMutablePointer<UInt>?,
        UnsafeMutablePointer<UInt>?
    ) -> UInt32
    private typealias MojoCreateInvitationFunction = @convention(c) (
        UnsafeRawPointer?,
        UnsafeMutablePointer<UInt>?
    ) -> UInt32
    private typealias MojoAttachMessagePipeToInvitationFunction = @convention(c) (
        UInt,
        UnsafeRawPointer?,
        UInt32,
        UnsafeRawPointer?,
        UnsafeMutablePointer<UInt>?
    ) -> UInt32
    private typealias MojoProcessErrorHandler = @convention(c) (
        UInt,
        UnsafeRawPointer?
    ) -> Void
    private typealias MojoSendInvitationFunction = @convention(c) (
        UInt,
        UnsafeRawPointer?,
        UnsafeRawPointer?,
        MojoProcessErrorHandler?,
        UInt,
        UnsafeRawPointer?
    ) -> UInt32
    private typealias MojoCloseFunction = @convention(c) (UInt) -> UInt32
    private typealias MojoCreateMessageFunction = @convention(c) (
        UnsafeRawPointer?,
        UnsafeMutablePointer<UInt>?
    ) -> UInt32
    private typealias MojoAppendMessageDataFunction = @convention(c) (
        UInt,
        UInt32,
        UnsafePointer<UInt>?,
        UInt32,
        UnsafeRawPointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UnsafeMutablePointer<UInt32>?
    ) -> UInt32
    private typealias MojoWriteMessageFunction = @convention(c) (
        UInt,
        UInt,
        UnsafeRawPointer?
    ) -> UInt32
    private typealias MojoDestroyMessageFunction = @convention(c) (UInt) -> UInt32
    private typealias MojoReadMessageFunction = @convention(c) (
        UInt,
        UnsafeRawPointer?,
        UnsafeMutablePointer<UInt>?
    ) -> UInt32
    private typealias MojoGetMessageDataFunction = @convention(c) (
        UInt,
        UnsafeRawPointer?,
        UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<UInt>?,
        UnsafeMutablePointer<UInt32>?
    ) -> UInt32
    private typealias MojoTrapEventHandler = @convention(c) (UnsafeRawPointer?) -> Void
    private typealias MojoCreateTrapFunction = @convention(c) (
        MojoTrapEventHandler,
        UnsafeRawPointer?,
        UnsafeMutablePointer<UInt>?
    ) -> UInt32
    private typealias MojoAddTriggerFunction = @convention(c) (
        UInt,
        UInt,
        UInt32,
        UInt32,
        UInt,
        UnsafeRawPointer?
    ) -> UInt32
    private typealias MojoArmTrapFunction = @convention(c) (
        UInt,
        UnsafeRawPointer?,
        UnsafeMutablePointer<UInt32>?,
        UnsafeMutableRawPointer?
    ) -> UInt32

    private static let mojoResultOK: UInt32 = 0
    public static let mojoResultFailedPrecondition: UInt32 = 9
    private static let mojoResultShouldWait: UInt32 = 17
    private static let mojoAppendMessageDataFlagCommitSize: UInt32 = 1
    private static let mojoGetMessageDataFlagIgnoreHandles: UInt32 = 1
    private static let mojoHandleSignalReadable: UInt32 = 1 << 0
    private static let mojoTriggerConditionSignalsSatisfied: UInt32 = 1
    private static let mojoInvitationTransportTypeChannel: UInt32 = 0
    private static let mojoPlatformHandleTypeMachSendRight: UInt32 = 2

    private let createMessagePipeFunction: MojoCreateMessagePipeFunction
    private let createInvitationFunction: MojoCreateInvitationFunction
    private let attachMessagePipeToInvitationFunction: MojoAttachMessagePipeToInvitationFunction
    private let sendInvitationFunction: MojoSendInvitationFunction
    private let closeFunction: MojoCloseFunction
    private let createMessageFunction: MojoCreateMessageFunction
    private let appendMessageDataFunction: MojoAppendMessageDataFunction
    private let writeMessageFunction: MojoWriteMessageFunction
    private let destroyMessageFunction: MojoDestroyMessageFunction
    private let readMessageFunction: MojoReadMessageFunction
    private let getMessageDataFunction: MojoGetMessageDataFunction
    private let createTrapFunction: MojoCreateTrapFunction
    private let addTriggerFunction: MojoAddTriggerFunction
    private let armTrapFunction: MojoArmTrapFunction

    public init(libraryHandle: UnsafeMutableRawPointer) throws {
        self.createMessagePipeFunction = try Self.loadSymbol(
            "MojoCreateMessagePipe",
            from: libraryHandle,
            as: MojoCreateMessagePipeFunction.self
        )
        self.createInvitationFunction = try Self.loadSymbol(
            "MojoCreateInvitation",
            from: libraryHandle,
            as: MojoCreateInvitationFunction.self
        )
        self.attachMessagePipeToInvitationFunction = try Self.loadSymbol(
            "MojoAttachMessagePipeToInvitation",
            from: libraryHandle,
            as: MojoAttachMessagePipeToInvitationFunction.self
        )
        self.sendInvitationFunction = try Self.loadSymbol(
            "MojoSendInvitation",
            from: libraryHandle,
            as: MojoSendInvitationFunction.self
        )
        self.closeFunction = try Self.loadSymbol(
            "MojoClose",
            from: libraryHandle,
            as: MojoCloseFunction.self
        )
        self.createMessageFunction = try Self.loadSymbol(
            "MojoCreateMessage",
            from: libraryHandle,
            as: MojoCreateMessageFunction.self
        )
        self.appendMessageDataFunction = try Self.loadSymbol(
            "MojoAppendMessageData",
            from: libraryHandle,
            as: MojoAppendMessageDataFunction.self
        )
        self.writeMessageFunction = try Self.loadSymbol(
            "MojoWriteMessage",
            from: libraryHandle,
            as: MojoWriteMessageFunction.self
        )
        self.destroyMessageFunction = try Self.loadSymbol(
            "MojoDestroyMessage",
            from: libraryHandle,
            as: MojoDestroyMessageFunction.self
        )
        self.readMessageFunction = try Self.loadSymbol(
            "MojoReadMessage",
            from: libraryHandle,
            as: MojoReadMessageFunction.self
        )
        self.getMessageDataFunction = try Self.loadSymbol(
            "MojoGetMessageData",
            from: libraryHandle,
            as: MojoGetMessageDataFunction.self
        )
        self.createTrapFunction = try Self.loadSymbol(
            "MojoCreateTrap",
            from: libraryHandle,
            as: MojoCreateTrapFunction.self
        )
        self.addTriggerFunction = try Self.loadSymbol(
            "MojoAddTrigger",
            from: libraryHandle,
            as: MojoAddTriggerFunction.self
        )
        self.armTrapFunction = try Self.loadSymbol(
            "MojoArmTrap",
            from: libraryHandle,
            as: MojoArmTrapFunction.self
        )
    }

    public func createMessagePipe() throws -> MojoMessagePipe {
        var endpoint0: UInt = 0
        var endpoint1: UInt = 0
        let result = createMessagePipeFunction(nil, &endpoint0, &endpoint1)
        guard result == Self.mojoResultOK else {
            throw MojoSystemError("MojoCreateMessagePipe failed with result \(result)")
        }
        let pipe = MojoMessagePipe(
            endpoint0: MojoHandle(rawValue: endpoint0),
            endpoint1: MojoHandle(rawValue: endpoint1)
        )
        guard pipe.endpoint0.isValid, pipe.endpoint1.isValid else {
            throw MojoSystemError("MojoCreateMessagePipe returned an invalid endpoint")
        }
        return pipe
    }

    public func createInvitation() throws -> MojoHandle {
        var invitation: UInt = 0
        var options = MojoCreateInvitationOptions(
            structSize: UInt32(MemoryLayout<MojoCreateInvitationOptions>.size),
            flags: 0
        )
        let result = withUnsafePointer(to: &options) { optionsPointer in
            createInvitationFunction(UnsafeRawPointer(optionsPointer), &invitation)
        }
        guard result == Self.mojoResultOK else {
            throw MojoSystemError("MojoCreateInvitation failed with result \(result)")
        }
        let handle = MojoHandle(rawValue: invitation)
        guard handle.isValid else {
            throw MojoSystemError("MojoCreateInvitation returned an invalid invitation")
        }
        return handle
    }

    public func attachMessagePipe(toInvitation invitation: MojoHandle, name: UInt64) throws -> MojoHandle {
        guard invitation.isValid else {
            throw MojoSystemError("cannot attach a Mojo message pipe to an invalid invitation")
        }
        var localPipe: UInt = 0
        var littleEndianName = name.littleEndian
        var options = MojoAttachMessagePipeToInvitationOptions(
            structSize: UInt32(MemoryLayout<MojoAttachMessagePipeToInvitationOptions>.size),
            flags: 0
        )
        let result = withUnsafeBytes(of: &littleEndianName) { nameBytes in
            withUnsafePointer(to: &options) { optionsPointer in
                attachMessagePipeToInvitationFunction(
                    invitation.rawValue,
                    nameBytes.baseAddress,
                    UInt32(nameBytes.count),
                    UnsafeRawPointer(optionsPointer),
                    &localPipe
                )
            }
        }
        guard result == Self.mojoResultOK else {
            throw MojoSystemError("MojoAttachMessagePipeToInvitation failed with result \(result)")
        }
        let handle = MojoHandle(rawValue: localPipe)
        guard handle.isValid else {
            throw MojoSystemError("MojoAttachMessagePipeToInvitation returned an invalid pipe")
        }
        return handle
    }

    public func sendInvitation(_ invitation: MojoHandle, toProcessID processID: pid_t, machSendRight: mach_port_t) throws {
        guard invitation.isValid else {
            throw MojoSystemError("cannot send an invalid Mojo invitation")
        }
        guard processID > 0 else {
            throw MojoSystemError("cannot send a Mojo invitation to invalid process id \(processID)")
        }
        guard machSendRight != MACH_PORT_NULL else {
            throw MojoSystemError("cannot send a Mojo invitation over a null Mach send right")
        }

        var processHandle = MojoPlatformProcessHandle(
            structSize: UInt32(MemoryLayout<MojoPlatformProcessHandle>.size),
            value: UInt64(processID)
        )
        var platformHandle = MojoPlatformHandle(
            structSize: UInt32(MemoryLayout<MojoPlatformHandle>.size),
            type: Self.mojoPlatformHandleTypeMachSendRight,
            value: UInt64(machSendRight)
        )
        var options = MojoSendInvitationOptions(
            structSize: UInt32(MemoryLayout<MojoSendInvitationOptions>.size),
            flags: 0,
            isolatedConnectionName: nil,
            isolatedConnectionNameLength: 0,
            reservedPadding: 0
        )
        let result = withUnsafePointer(to: &processHandle) { processPointer in
            withUnsafePointer(to: &platformHandle) { platformPointer in
                var endpoint = MojoInvitationTransportEndpoint(
                    structSize: UInt32(MemoryLayout<MojoInvitationTransportEndpoint>.size),
                    type: Self.mojoInvitationTransportTypeChannel,
                    numPlatformHandles: 1,
                    platformHandles: platformPointer
                )
                return withUnsafePointer(to: &endpoint) { endpointPointer in
                    withUnsafePointer(to: &options) { optionsPointer in
                        sendInvitationFunction(
                            invitation.rawValue,
                            UnsafeRawPointer(processPointer),
                            UnsafeRawPointer(endpointPointer),
                            Optional<MojoProcessErrorHandler>.none,
                            0,
                            UnsafeRawPointer(optionsPointer)
                        )
                    }
                }
            }
        }
        guard result == Self.mojoResultOK else {
            throw MojoSystemError("MojoSendInvitation failed with result \(result)")
        }
    }

    public func close(_ handle: MojoHandle) throws {
        guard handle.isValid else {
            return
        }
        let result = closeFunction(handle.rawValue)
        guard result == Self.mojoResultOK else {
            throw MojoSystemError("MojoClose(\(handle.rawValue)) failed with result \(result)")
        }
    }

    public func writeMessage(pipe: MojoHandle, data: Data, handles: [MojoHandle] = []) throws {
        guard pipe.isValid else {
            throw MojoSystemError("cannot write Mojo message to an invalid pipe")
        }
        guard data.count <= UInt32.max else {
            throw MojoSystemError("Mojo message payload is too large: \(data.count) bytes")
        }
        var message: UInt = 0
        let createResult = createMessageFunction(nil, &message)
        guard createResult == Self.mojoResultOK, message != 0 else {
            throw MojoSystemError("MojoCreateMessage failed with result \(createResult)")
        }

        var appendOptions = MojoAppendMessageDataOptions(
            structSize: UInt32(MemoryLayout<MojoAppendMessageDataOptions>.size),
            flags: Self.mojoAppendMessageDataFlagCommitSize
        )
        var buffer: UnsafeMutableRawPointer?
        var bufferSize: UInt32 = 0
        let rawHandles = handles.map(\.rawValue)
        let appendResult = withUnsafePointer(to: &appendOptions) { optionsPointer in
            rawHandles.withUnsafeBufferPointer { handlesPointer in
                appendMessageDataFunction(
                    message,
                    UInt32(data.count),
                    handlesPointer.isEmpty ? nil : handlesPointer.baseAddress,
                    UInt32(handlesPointer.count),
                    UnsafeRawPointer(optionsPointer),
                    &buffer,
                    &bufferSize
                )
            }
        }
        guard appendResult == Self.mojoResultOK, let buffer else {
            _ = destroyMessageFunction(message)
            throw MojoSystemError("MojoAppendMessageData failed with result \(appendResult)")
        }
        guard bufferSize >= data.count else {
            _ = destroyMessageFunction(message)
            throw MojoSystemError("MojoAppendMessageData returned \(bufferSize) bytes for \(data.count)-byte payload")
        }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)

        let writeResult = writeMessageFunction(pipe.rawValue, message, nil)
        guard writeResult == Self.mojoResultOK else {
            throw MojoSystemError(
                "MojoWriteMessage(\(pipe.rawValue)) failed with result \(writeResult)",
                result: writeResult
            )
        }
    }

    public func readMessage(pipe: MojoHandle, timeout: TimeInterval) throws -> Data {
        guard pipe.isValid else {
            throw MojoSystemError("cannot read Mojo message from an invalid pipe")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let data = try readMessageIfAvailable(pipe: pipe) {
                return data
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw MojoSystemError("MojoReadMessage(\(pipe.rawValue)) timed out")
            }
            try waitUntilReadable(pipe: pipe, timeout: remaining)
        }
    }

    public func readMessageIfAvailable(pipe: MojoHandle) throws -> Data? {
        var message: UInt = 0
        var options = MojoReadMessageOptions(
            structSize: UInt32(MemoryLayout<MojoReadMessageOptions>.size),
            flags: 0
        )
        let readResult = withUnsafePointer(to: &options) { optionsPointer in
            readMessageFunction(pipe.rawValue, UnsafeRawPointer(optionsPointer), &message)
        }
        switch readResult {
        case Self.mojoResultOK:
            guard message != 0 else {
                throw MojoSystemError("MojoReadMessage(\(pipe.rawValue)) returned an invalid message")
            }
            defer { _ = destroyMessageFunction(message) }
            return try data(fromMessage: message)
        case Self.mojoResultShouldWait:
            return nil
        case Self.mojoResultFailedPrecondition:
            throw MojoSystemError(
                "MojoReadMessage(\(pipe.rawValue)) failed with result \(readResult)",
                result: readResult
            )
        default:
            throw MojoSystemError(
                "MojoReadMessage(\(pipe.rawValue)) failed with result \(readResult)",
                result: readResult
            )
        }
    }

    private func data(fromMessage message: UInt) throws -> Data {
        var options = MojoGetMessageDataOptions(
            structSize: UInt32(MemoryLayout<MojoGetMessageDataOptions>.size),
            flags: Self.mojoGetMessageDataFlagIgnoreHandles
        )
        var buffer: UnsafeMutableRawPointer?
        var byteCount: UInt32 = 0
        let result = withUnsafePointer(to: &options) { optionsPointer in
            getMessageDataFunction(
                message,
                UnsafeRawPointer(optionsPointer),
                &buffer,
                &byteCount,
                nil,
                nil
            )
        }
        guard result == Self.mojoResultOK else {
            throw MojoSystemError("MojoGetMessageData failed with result \(result)")
        }
        guard byteCount == 0 || buffer != nil else {
            throw MojoSystemError("MojoGetMessageData returned \(byteCount) bytes with no buffer")
        }
        guard let buffer else {
            return Data()
        }
        return Data(bytes: buffer, count: Int(byteCount))
    }

    private func waitUntilReadable(pipe: MojoHandle, timeout: TimeInterval) throws {
        var trapHandle: UInt = 0
        var createOptions = MojoCreateTrapOptions(
            structSize: UInt32(MemoryLayout<MojoCreateTrapOptions>.size),
            flags: 0
        )
        let createResult = withUnsafePointer(to: &createOptions) { optionsPointer in
            createTrapFunction(Self.trapEventHandler, UnsafeRawPointer(optionsPointer), &trapHandle)
        }
        guard createResult == Self.mojoResultOK, trapHandle != 0 else {
            throw MojoSystemError("MojoCreateTrap failed with result \(createResult)")
        }

        let waiter = MojoTrapWaiter()
        let retainedWaiter = Unmanaged.passRetained(waiter)
        defer { retainedWaiter.release() }
        defer { try? close(MojoHandle(rawValue: trapHandle)) }
        var addOptions = MojoAddTriggerOptions(
            structSize: UInt32(MemoryLayout<MojoAddTriggerOptions>.size),
            flags: 0
        )
        let context = UInt(bitPattern: retainedWaiter.toOpaque())
        let addResult = withUnsafePointer(to: &addOptions) { optionsPointer in
            addTriggerFunction(
                trapHandle,
                pipe.rawValue,
                Self.mojoHandleSignalReadable,
                Self.mojoTriggerConditionSignalsSatisfied,
                context,
                UnsafeRawPointer(optionsPointer)
            )
        }
        guard addResult == Self.mojoResultOK else {
            throw MojoSystemError("MojoAddTrigger(\(pipe.rawValue)) failed with result \(addResult)")
        }

        var armOptions = MojoArmTrapOptions(
            structSize: UInt32(MemoryLayout<MojoArmTrapOptions>.size),
            flags: 0
        )
        let armResult = withUnsafePointer(to: &armOptions) { optionsPointer in
            armTrapFunction(
                trapHandle,
                UnsafeRawPointer(optionsPointer),
                nil,
                nil
            )
        }
        switch armResult {
        case Self.mojoResultOK:
            guard waiter.wait(timeout: timeout) else {
                throw MojoSystemError("MojoArmTrap(\(pipe.rawValue)) timed out")
            }
            if let result = waiter.result, result != Self.mojoResultOK {
                throw MojoSystemError("Mojo trap for \(pipe.rawValue) failed with result \(result)")
            }
        case Self.mojoResultFailedPrecondition:
            return
        default:
            throw MojoSystemError("MojoArmTrap(\(pipe.rawValue)) failed with result \(armResult)")
        }
    }

    private static func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw MojoSystemError("missing Mojo C system symbol \(name)")
        }
        return unsafeBitCast(symbol, to: type)
    }

    private static let trapEventHandler: MojoTrapEventHandler = { eventPointer in
        guard let eventPointer else {
            return
        }
        let event = eventPointer.assumingMemoryBound(to: MojoTrapEvent.self).pointee
        guard let contextPointer = UnsafeMutableRawPointer(bitPattern: event.triggerContext) else {
            return
        }
        let waiter = Unmanaged<MojoTrapWaiter>.fromOpaque(contextPointer).takeUnretainedValue()
        waiter.signal(result: event.result)
    }
}

private struct MojoAppendMessageDataOptions {
    let structSize: UInt32
    let flags: UInt32
}

public struct MojoCreateInvitationOptions {
    public let structSize: UInt32
    public let flags: UInt32
}

public struct MojoAttachMessagePipeToInvitationOptions {
    public let structSize: UInt32
    public let flags: UInt32
}

public struct MojoPlatformProcessHandle {
    public let structSize: UInt32
    public let value: UInt64
}

public struct MojoPlatformHandle {
    public let structSize: UInt32
    public let type: UInt32
    public let value: UInt64
}

public struct MojoInvitationTransportEndpoint {
    public let structSize: UInt32
    public let type: UInt32
    public let numPlatformHandles: UInt32
    public let platformHandles: UnsafePointer<MojoPlatformHandle>?
}

public struct MojoSendInvitationOptions {
    public let structSize: UInt32
    public let flags: UInt32
    public let isolatedConnectionName: UnsafePointer<CChar>?
    public let isolatedConnectionNameLength: UInt32
    public let reservedPadding: UInt32
}

public struct MojoProcessErrorDetails {
    public let structSize: UInt32
    public let errorMessageLength: UInt32
    public let errorMessage: UnsafePointer<CChar>?
    public let flags: UInt32
    public let reservedPadding: UInt32
}

private struct MojoReadMessageOptions {
    let structSize: UInt32
    let flags: UInt32
}

private struct MojoGetMessageDataOptions {
    let structSize: UInt32
    let flags: UInt32
}

private struct MojoCreateTrapOptions {
    let structSize: UInt32
    let flags: UInt32
}

private struct MojoAddTriggerOptions {
    let structSize: UInt32
    let flags: UInt32
}

private struct MojoArmTrapOptions {
    let structSize: UInt32
    let flags: UInt32
}

private struct MojoHandleSignalsState {
    var satisfiedSignals: UInt32 = 0
    var satisfiableSignals: UInt32 = 0
}

private struct MojoTrapEvent {
    var structSize: UInt32 = UInt32(MemoryLayout<MojoTrapEvent>.size)
    var flags: UInt32 = 0
    var triggerContext: UInt = 0
    var result: UInt32 = 0
    var signalsState: MojoHandleSignalsState = MojoHandleSignalsState()
}

private final class MojoTrapWaiter {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var result: UInt32?

    func signal(result: UInt32) {
        lock.withLock {
            if self.result == nil {
                self.result = result
                semaphore.signal()
            }
        }
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}
