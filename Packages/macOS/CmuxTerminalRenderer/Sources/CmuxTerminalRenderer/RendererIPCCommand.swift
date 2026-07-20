public import Foundation
internal import XPC

/// Typed builders for messages sent on the input hot path.
public enum RendererIPCCommand {
    public static func createSurface(
        _ configuration: RendererSurfaceConfiguration
    ) throws -> RendererXPCObject {
        let message = RendererIPCMessage.make(.createSurface)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(configuration)
        RendererIPCMessage.setData(
            payload,
            forKey: RendererIPCKey.configuration,
            in: message
        )
        return RendererXPCObject(message)
    }

    public static func surface(
        operation: RendererIPCOperation,
        identity: RendererSurfaceIdentity
    ) -> xpc_object_t {
        let message = RendererIPCMessage.make(operation)
        RendererIPCMessage.setUUID(
            identity.workspaceID,
            forKey: RendererIPCKey.workspaceID,
            in: message
        )
        RendererIPCMessage.setUUID(
            identity.surfaceID,
            forKey: RendererIPCKey.surfaceID,
            in: message
        )
        xpc_dictionary_set_uint64(
            message,
            RendererIPCKey.generation,
            identity.generation
        )
        return message
    }

    public static func resize(
        identity: RendererSurfaceIdentity,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        scaleX: Double,
        scaleY: Double
    ) -> RendererXPCObject {
        let message = surface(operation: .resize, identity: identity)
        xpc_dictionary_set_uint64(message, RendererIPCKey.width, UInt64(pixelWidth))
        xpc_dictionary_set_uint64(message, RendererIPCKey.height, UInt64(pixelHeight))
        xpc_dictionary_set_double(message, RendererIPCKey.scaleX, scaleX)
        xpc_dictionary_set_double(message, RendererIPCKey.scaleY, scaleY)
        return RendererXPCObject(message)
    }

    public static func focus(
        identity: RendererSurfaceIdentity,
        focused: Bool
    ) -> RendererXPCObject {
        let message = surface(operation: .focus, identity: identity)
        xpc_dictionary_set_bool(message, RendererIPCKey.value, focused)
        return RendererXPCObject(message)
    }

    public static func text(
        identity: RendererSurfaceIdentity,
        text: String,
        marked: Bool
    ) -> RendererXPCObject {
        let message = surface(
            operation: marked ? .markedText : .text,
            identity: identity
        )
        xpc_dictionary_set_string(message, RendererIPCKey.text, text)
        return RendererXPCObject(message)
    }

    public static func key(
        identity: RendererSurfaceIdentity,
        action: UInt32,
        modifiers: UInt32,
        consumedModifiers: UInt32,
        keycode: UInt32,
        text: String?,
        unshiftedCodepoint: UInt32,
        composing: Bool
    ) -> RendererXPCObject {
        let message = keyFields(
            identity: identity,
            action: action,
            modifiers: modifiers,
            consumedModifiers: consumedModifiers,
            keycode: keycode,
            unshiftedCodepoint: unshiftedCodepoint,
            composing: composing
        )
        if let text {
            xpc_dictionary_set_string(message, RendererIPCKey.text, text)
        }
        return RendererXPCObject(message)
    }

    /// Key builder for Ghostty's hot input path. XPC copies the temporary C
    /// string before returning, avoiding an intermediate Swift allocation.
    public static func key(
        identity: RendererSurfaceIdentity,
        action: UInt32,
        modifiers: UInt32,
        consumedModifiers: UInt32,
        keycode: UInt32,
        textPointer: UnsafePointer<CChar>?,
        unshiftedCodepoint: UInt32,
        composing: Bool
    ) -> RendererXPCObject {
        let message = keyFields(
            identity: identity,
            action: action,
            modifiers: modifiers,
            consumedModifiers: consumedModifiers,
            keycode: keycode,
            unshiftedCodepoint: unshiftedCodepoint,
            composing: composing
        )
        if let textPointer {
            xpc_dictionary_set_string(message, RendererIPCKey.text, textPointer)
        }
        return RendererXPCObject(message)
    }

    private static func keyFields(
        identity: RendererSurfaceIdentity,
        action: UInt32,
        modifiers: UInt32,
        consumedModifiers: UInt32,
        keycode: UInt32,
        unshiftedCodepoint: UInt32,
        composing: Bool
    ) -> xpc_object_t {
        let message = surface(operation: .key, identity: identity)
        xpc_dictionary_set_uint64(message, RendererIPCKey.action, UInt64(action))
        xpc_dictionary_set_uint64(message, RendererIPCKey.modifiers, UInt64(modifiers))
        xpc_dictionary_set_uint64(
            message,
            RendererIPCKey.consumedModifiers,
            UInt64(consumedModifiers)
        )
        xpc_dictionary_set_uint64(message, RendererIPCKey.keycode, UInt64(keycode))
        xpc_dictionary_set_uint64(
            message,
            RendererIPCKey.unshiftedCodepoint,
            UInt64(unshiftedCodepoint)
        )
        xpc_dictionary_set_bool(message, RendererIPCKey.composing, composing)
        return message
    }

    public static func mousePosition(
        identity: RendererSurfaceIdentity,
        x: Double,
        y: Double,
        modifiers: UInt32
    ) -> RendererXPCObject {
        let message = surface(operation: .mousePosition, identity: identity)
        xpc_dictionary_set_double(message, RendererIPCKey.positionX, x)
        xpc_dictionary_set_double(message, RendererIPCKey.positionY, y)
        xpc_dictionary_set_uint64(message, RendererIPCKey.modifiers, UInt64(modifiers))
        return RendererXPCObject(message)
    }

    public static func mouseButton(
        identity: RendererSurfaceIdentity,
        state: UInt32,
        button: UInt32,
        modifiers: UInt32
    ) -> RendererXPCObject {
        let message = surface(operation: .mouseButton, identity: identity)
        xpc_dictionary_set_uint64(message, RendererIPCKey.action, UInt64(state))
        xpc_dictionary_set_uint64(message, RendererIPCKey.button, UInt64(button))
        xpc_dictionary_set_uint64(message, RendererIPCKey.modifiers, UInt64(modifiers))
        return RendererXPCObject(message)
    }

    public static func mouseScroll(
        identity: RendererSurfaceIdentity,
        x: Double,
        y: Double,
        packedModifiers: Int32
    ) -> RendererXPCObject {
        let message = surface(operation: .mouseScroll, identity: identity)
        xpc_dictionary_set_double(message, RendererIPCKey.positionX, x)
        xpc_dictionary_set_double(message, RendererIPCKey.positionY, y)
        xpc_dictionary_set_int64(message, RendererIPCKey.modifiers, Int64(packedModifiers))
        return RendererXPCObject(message)
    }

    public static func mousePressure(
        identity: RendererSurfaceIdentity,
        stage: UInt32,
        pressure: Double
    ) -> RendererXPCObject {
        let message = surface(operation: .mousePressure, identity: identity)
        xpc_dictionary_set_uint64(message, RendererIPCKey.action, UInt64(stage))
        xpc_dictionary_set_double(message, RendererIPCKey.pressure, pressure)
        return RendererXPCObject(message)
    }

    public static func bindingAction(
        identity: RendererSurfaceIdentity,
        action: String
    ) -> RendererXPCObject {
        let message = surface(operation: .action, identity: identity)
        xpc_dictionary_set_string(message, RendererIPCKey.text, action)
        return RendererXPCObject(message)
    }
}
