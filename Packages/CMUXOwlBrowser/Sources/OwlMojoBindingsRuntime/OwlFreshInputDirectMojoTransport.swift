import Foundation
import OwlMojoBindingsGenerated
import OwlMojoSystem

public final class OwlFreshInputDirectMojoTransport {
    private let writer: MojoMessageWriting
    private let closer: MojoMessagePipeCreating
    private let remoteHandle: MojoHandle
    private var ownsRemoteHandle = true

    public init(writer: MojoMessageWriting, closer: MojoMessagePipeCreating, remoteHandle: UInt64) {
        self.writer = writer
        self.closer = closer
        self.remoteHandle = MojoHandle(rawValue: UInt(remoteHandle))
    }

    deinit {
        if ownsRemoteHandle {
            try? closer.close(remoteHandle)
        }
    }

    public func sendMouse(_ event: OwlFreshMouseEvent) throws {
        try write(method: .sendMouse, payload: OwlFreshInputWireMessage.sendMousePayload(event))
    }

    public func sendWheel(_ event: OwlFreshWheelEvent) throws {
        try write(method: .sendWheel, payload: OwlFreshInputWireMessage.sendWheelPayload(event))
    }

    public func sendKey(_ event: OwlFreshKeyEvent) throws {
        try write(method: .sendKey, payload: OwlFreshInputWireMessage.sendKeyPayload(event))
    }

    public func sendComposition(_ event: OwlFreshCompositionEvent) throws {
        try write(method: .sendComposition, payload: OwlFreshInputWireMessage.sendCompositionPayload(event))
    }

    public func executeEditCommand(_ command: String) throws {
        try write(method: .executeEditCommand, payload: OwlFreshInputWireMessage.executeEditCommandPayload(command))
    }

    private func write(method: OwlFreshInputWireMessage.Method, payload: Data) throws {
        try writer.writeMessage(
            pipe: remoteHandle,
            data: OwlFreshInputWireMessage.message(method: method, payload: payload),
            handles: []
        )
    }
}

public enum OwlFreshInputWireMessage {
    public enum Method: UInt32 {
        case sendMouse = 0
        case sendWheel = 1
        case sendKey = 2
        case sendComposition = 3
        case executeEditCommand = 4
    }

    public static func message(method: Method, payload: Data) -> Data {
        MojoWireMessage.message(method: method.rawValue, payload: payload)
    }

    public static func sendMousePayload(_ event: OwlFreshMouseEvent) -> Data {
        let eventData = mouseEventData(event)
        var data = Data(count: 16 + eventData.count)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + eventData.count, with: eventData)
        return data
    }

    public static func sendKeyPayload(_ event: OwlFreshKeyEvent) -> Data {
        let eventData = keyEventData(event)
        var data = Data(count: MojoWireMessage.align(16 + eventData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + eventData.count, with: eventData)
        return data
    }

    public static func sendWheelPayload(_ event: OwlFreshWheelEvent) -> Data {
        let eventData = wheelEventData(event)
        var data = Data(count: MojoWireMessage.align(16 + eventData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + eventData.count, with: eventData)
        return data
    }

    public static func sendCompositionPayload(_ event: OwlFreshCompositionEvent) -> Data {
        let eventData = compositionEventData(event)
        var data = Data(count: MojoWireMessage.align(16 + eventData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + eventData.count, with: eventData)
        return data
    }

    public static func executeEditCommandPayload(_ command: String) -> Data {
        let stringData = MojoWireMessage.utf8String(command)
        var data = Data(count: MojoWireMessage.align(16 + stringData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + stringData.count, with: stringData)
        return data
    }

    private static func mouseEventData(_ event: OwlFreshMouseEvent) -> Data {
        var data = Data(count: 40)
        data.writeUInt32(40, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(event.kind.rawValue, at: 8)
        data.writeFloat32(event.x, at: 12)
        data.writeFloat32(event.y, at: 16)
        data.writeUInt32(event.button, at: 20)
        data.writeUInt32(event.clickCount, at: 24)
        data.writeFloat32(event.deltaX, at: 28)
        data.writeFloat32(event.deltaY, at: 32)
        data.writeUInt32(event.modifiers, at: 36)
        return data
    }

    private static func wheelEventData(_ event: OwlFreshWheelEvent) -> Data {
        var data = Data(count: 48)
        data.writeUInt32(48, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeFloat32(event.x, at: 8)
        data.writeFloat32(event.y, at: 12)
        data.writeFloat32(event.deltaX, at: 16)
        data.writeFloat32(event.deltaY, at: 20)
        data.writeFloat32(event.wheelTicksX, at: 24)
        data.writeFloat32(event.wheelTicksY, at: 28)
        data.writeUInt32(event.phase, at: 32)
        data.writeUInt32(event.momentumPhase, at: 36)
        data.writeUInt32(event.modifiers, at: 40)
        data.writeUInt32(event.deltaUnits, at: 44)
        return data
    }

    private static func keyEventData(_ event: OwlFreshKeyEvent) -> Data {
        let stringData = MojoWireMessage.utf8String(event.text)
        let editCommandsData = MojoWireMessage.stringArray(event.editCommands)
        let charactersData = MojoWireMessage.utf8String(event.characters)
        let charactersIgnoringModifiersData = MojoWireMessage.utf8String(event.charactersIgnoringModifiers)
        var data = Data(count: 64)
        data.writeUInt32(64, at: 0)
        data.writeUInt32(0, at: 4)
        data[8] = (event.keyDown ? 1 : 0) | (event.isRepeat ? 2 : 0)
        data.writeUInt32(event.keyCode, at: 12)
        data.writeUInt32(event.modifiers, at: 24)
        data.writeUInt32(event.nativeEventType, at: 28)
        data.writeUInt32(event.nativeKeyCode, at: 40)
        data.appendMojoPointer(child: stringData, pointerOffset: 16)
        data.appendMojoPointer(child: editCommandsData, pointerOffset: 32)
        data.appendMojoPointer(child: charactersData, pointerOffset: 48)
        data.appendMojoPointer(child: charactersIgnoringModifiersData, pointerOffset: 56)
        return data
    }

    private static func compositionEventData(_ event: OwlFreshCompositionEvent) -> Data {
        let textData = MojoWireMessage.utf8String(event.text)
        var data = Data(count: 32)
        data.writeUInt32(32, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(event.kind.rawValue, at: 8)
        data.writeUInt32(event.selectionStart, at: 12)
        data.writeUInt32(event.selectionEnd, at: 24)
        data[28] = event.keepSelection ? 1 : 0
        data.appendMojoPointer(child: textData, pointerOffset: 16)
        return data
    }
}
