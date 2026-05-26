import AppKit
import Foundation
import OwlMojoBindingsGenerated

@MainActor
public final class OwlInputEventAuditLogger {
    public static let shared = OwlInputEventAuditLogger()

    private var handle: FileHandle?
    private var lastCursorSignature: CursorRecordSignature?

    private init() {}

    public static func configure(path: String?) {
        shared.configure(path: path)
    }

    static func recordMouse(
        kind: OwlFreshMouseKind,
        event: NSEvent,
        host: NSView,
        browserX: Float,
        browserY: Float
    ) {
        shared.record(
            name: "mouse.\(kind)",
            event: event,
            host: host,
            browserX: browserX,
            browserY: browserY
        )
    }

    static func recordWheel(
        event: NSEvent,
        host: NSView,
        wheel: OwlFreshWheelEvent
    ) {
        shared.record(
            name: "wheel",
            event: event,
            host: host,
            browserX: wheel.x,
            browserY: wheel.y,
            extraFields: [
                "scrollingDeltaX": Double(event.scrollingDeltaX),
                "scrollingDeltaY": Double(event.scrollingDeltaY),
                "deltaX": Double(event.deltaX),
                "deltaY": Double(event.deltaY),
                "hasPreciseScrollingDeltas": event.hasPreciseScrollingDeltas,
                "phaseRaw": Int(event.phase.rawValue),
                "momentumPhaseRaw": Int(event.momentumPhase.rawValue),
                "wheelDeltaX": Double(wheel.deltaX),
                "wheelDeltaY": Double(wheel.deltaY),
                "wheelTicksX": Double(wheel.wheelTicksX),
                "wheelTicksY": Double(wheel.wheelTicksY),
                "wheelPhase": Int(wheel.phase),
                "wheelMomentumPhase": Int(wheel.momentumPhase),
                "wheelDeltaUnits": Int(wheel.deltaUnits)
            ]
        )
    }

    static func recordKey(
        name: String,
        event: NSEvent,
        host: NSView,
        key: OwlFreshKeyEvent
    ) {
        shared.record(
            name: name,
            event: event,
            host: host,
            browserX: 0,
            browserY: 0,
            extraFields: [
                "hasCharacters": event.characters?.isEmpty == false,
                "charactersLength": event.characters?.count ?? 0,
                "hasCharactersIgnoringModifiers": event.charactersIgnoringModifiers?.isEmpty == false,
                "charactersIgnoringModifiersLength": event.charactersIgnoringModifiers?.count ?? 0,
                "nativeKeyCode": Int(event.keyCode),
                "keyDown": key.keyDown,
                "keyCode": Int(key.keyCode),
                "hasText": !key.text.isEmpty,
                "textLength": key.text.count,
                "keyModifiers": Int(key.modifiers),
                "keyNativeEventType": Int(key.nativeEventType),
                "keyNativeKeyCode": Int(key.nativeKeyCode),
                "keyIsRepeat": key.isRepeat,
                "keyCharactersLength": key.characters.count,
                "keyCharactersIgnoringModifiersLength": key.charactersIgnoringModifiers.count,
                "editCommands": key.editCommands
            ]
        )
    }

    static func recordComposition(
        _ composition: OwlFreshCompositionEvent,
        host: NSView
    ) {
        shared.recordComposition(composition, host: host)
    }

    static func recordCursor(
        _ cursor: OwlFreshCursorInfo,
        nativeCursorName: String,
        host: NSView,
        suppressBrowserCursor: Bool
    ) {
        shared.recordCursor(
            cursor,
            nativeCursorName: nativeCursorName,
            host: host,
            suppressBrowserCursor: suppressBrowserCursor
        )
    }

    static func recordTextInputContext(
        name: String,
        host: NSView,
        trigger: String,
        requestedInputSourceID: String,
        activated: Bool,
        availableInputSourceIDs: [String],
        selectedInputSourceBefore: String?,
        selectedInputSourceAfter: String?
    ) {
        shared.recordTextInputContext(
            name: name,
            host: host,
            trigger: trigger,
            requestedInputSourceID: requestedInputSourceID,
            activated: activated,
            availableInputSourceIDs: availableInputSourceIDs,
            selectedInputSourceBefore: selectedInputSourceBefore,
            selectedInputSourceAfter: selectedInputSourceAfter
        )
    }

    static func recordNativeSurface(
        name: String,
        surface: OwlFreshSurfaceInfo,
        host: NSView,
        extraFields: [String: Any] = [:]
    ) {
        shared.recordNativeSurface(
            name: name,
            surface: surface,
            host: host,
            extraFields: extraFields
        )
    }

    static func recordHostedSurface(
        name: String,
        surface: OwlFreshSurfaceInfo,
        host: NSView,
        extraFields: [String: Any] = [:]
    ) {
        shared.recordSurface(
            name: name,
            surface: surface,
            host: host,
            extraFields: extraFields
        )
    }

    private func configure(path: String?) {
        close()
        lastCursorSignature = nil
        guard let path, !path.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        } catch {
            handle = nil
        }
    }

    private func close() {
        handle?.synchronizeFile()
        try? handle?.close()
        handle = nil
        lastCursorSignature = nil
    }

    private func record(
        name: String,
        event: NSEvent,
        host: NSView,
        browserX: Float,
        browserY: Float,
        extraFields: [String: Any] = [:]
    ) {
        guard self.handle != nil else {
            return
        }
        let window = host.window
        let locationInHost = host.convert(event.locationInWindow, from: nil)
        var payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "name": name,
            "eventType": event.type.debugName,
            "eventTypeRaw": UInt64(event.type.rawValue),
            "windowNumber": event.windowNumber,
            "modifierFlags": UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue),
            "locationInWindow": [
                "x": event.locationInWindow.x,
                "y": event.locationInWindow.y
            ],
            "locationInHost": [
                "x": locationInHost.x,
                "y": locationInHost.y
            ],
            "browserPoint": [
                "x": browserX,
                "y": browserY
            ],
            "clickCount": event.mouseClickCountForAudit,
            "buttonNumber": event.mouseButtonNumberForAudit,
            "hostBounds": [
                "x": host.bounds.origin.x,
                "y": host.bounds.origin.y,
                "width": host.bounds.width,
                "height": host.bounds.height
            ],
            "windowIsKey": window?.isKeyWindow ?? false,
            "windowAcceptsMouseMovedEvents": window?.acceptsMouseMovedEvents ?? false,
            "firstResponderIsHost": window?.firstResponder === host
        ]
        for (key, value) in extraFields {
            payload[key] = value
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        write(data)
    }

    private func recordCursor(
        _ cursor: OwlFreshCursorInfo,
        nativeCursorName: String,
        host: NSView,
        suppressBrowserCursor: Bool
    ) {
        guard self.handle != nil else {
            return
        }
        let window = host.window
        let signature = CursorRecordSignature(
            rawType: cursor.type,
            nativeCursorName: nativeCursorName,
            suppressBrowserCursor: suppressBrowserCursor,
            windowIsKey: window?.isKeyWindow ?? false
        )
        guard signature != lastCursorSignature else {
            return
        }
        lastCursorSignature = signature
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "name": "cursor.apply",
            "cursorRawType": cursor.type,
            "cursorType": cursor.cursorType.wireName,
            "nativeCursor": nativeCursorName,
            "suppressBrowserCursor": suppressBrowserCursor,
            "windowIsKey": window?.isKeyWindow ?? false,
            "hostBounds": [
                "x": host.bounds.origin.x,
                "y": host.bounds.origin.y,
                "width": host.bounds.width,
                "height": host.bounds.height
            ]
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        write(data)
    }

    private func recordNativeSurface(
        name: String,
        surface: OwlFreshSurfaceInfo,
        host: NSView,
        extraFields: [String: Any]
    ) {
        recordSurface(
            name: name,
            surface: surface,
            host: host,
            extraFields: extraFields
        )
    }

    private func recordSurface(
        name: String,
        surface: OwlFreshSurfaceInfo,
        host: NSView,
        extraFields: [String: Any]
    ) {
        guard self.handle != nil else {
            return
        }
        let window = host.window
        var payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "name": name,
            "surfaceId": surface.surfaceId,
            "surfaceKind": surface.kind.rawValue,
            "surfaceLabel": surface.label,
            "surfaceX": surface.x,
            "surfaceY": surface.y,
            "surfaceWidth": surface.width,
            "surfaceHeight": surface.height,
            "nativeMenuItemCount": surface.nativeMenuItems.count,
            "legacyMenuItemCount": surface.menuItems.count,
            "hostBounds": [
                "x": host.bounds.origin.x,
                "y": host.bounds.origin.y,
                "width": host.bounds.width,
                "height": host.bounds.height
            ],
            "windowIsKey": window?.isKeyWindow ?? false,
            "windowNumber": window?.windowNumber ?? 0
        ]
        for (key, value) in extraFields {
            payload[key] = value
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        write(data)
    }

    private func recordComposition(_ composition: OwlFreshCompositionEvent, host: NSView) {
        guard self.handle != nil else {
            return
        }
        let window = host.window
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "name": "composition.\(composition.kind)",
            "compositionKind": composition.kind.rawValue,
            "hasCompositionText": !composition.text.isEmpty,
            "compositionTextLength": composition.text.count,
            "selectionStart": Int(composition.selectionStart),
            "selectionEnd": Int(composition.selectionEnd),
            "keepSelection": composition.keepSelection,
            "hostBounds": [
                "x": host.bounds.origin.x,
                "y": host.bounds.origin.y,
                "width": host.bounds.width,
                "height": host.bounds.height
            ],
            "windowIsKey": window?.isKeyWindow ?? false,
            "firstResponderIsHost": window?.firstResponder === host
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        write(data)
    }

    private func recordTextInputContext(
        name: String,
        host: NSView,
        trigger: String,
        requestedInputSourceID: String,
        activated: Bool,
        availableInputSourceIDs: [String],
        selectedInputSourceBefore: String?,
        selectedInputSourceAfter: String?
    ) {
        guard self.handle != nil else {
            return
        }
        let window = host.window
        let payload: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "name": name,
            "trigger": trigger,
            "requestedInputSourceID": requestedInputSourceID,
            "activated": activated,
            "availableInputSourceIDs": availableInputSourceIDs,
            "selectedInputSourceBefore": selectedInputSourceBefore ?? "",
            "selectedInputSourceAfter": selectedInputSourceAfter ?? "",
            "windowIsKey": window?.isKeyWindow ?? false,
            "firstResponderIsHost": window?.firstResponder === host,
            "hostBounds": [
                "x": host.bounds.origin.x,
                "y": host.bounds.origin.y,
                "width": host.bounds.width,
                "height": host.bounds.height
            ]
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        write(data)
    }

    private func write(_ data: Data) {
        guard let handle else {
            return
        }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

private struct CursorRecordSignature: Equatable {
    let rawType: Int32
    let nativeCursorName: String
    let suppressBrowserCursor: Bool
    let windowIsKey: Bool
}

private extension NSEvent.EventType {
    var debugName: String {
        switch self {
        case .leftMouseDown:
            return "leftMouseDown"
        case .leftMouseUp:
            return "leftMouseUp"
        case .rightMouseDown:
            return "rightMouseDown"
        case .rightMouseUp:
            return "rightMouseUp"
        case .mouseMoved:
            return "mouseMoved"
        case .leftMouseDragged:
            return "leftMouseDragged"
        case .rightMouseDragged:
            return "rightMouseDragged"
        case .mouseEntered:
            return "mouseEntered"
        case .mouseExited:
            return "mouseExited"
        case .scrollWheel:
            return "scrollWheel"
        case .keyDown:
            return "keyDown"
        case .keyUp:
            return "keyUp"
        case .flagsChanged:
            return "flagsChanged"
        case .otherMouseDown:
            return "otherMouseDown"
        case .otherMouseUp:
            return "otherMouseUp"
        case .otherMouseDragged:
            return "otherMouseDragged"
        default:
            return "event-\(rawValue)"
        }
    }

    var isMouseEventForAudit: Bool {
        switch self {
        case .leftMouseDown,
             .leftMouseUp,
             .rightMouseDown,
             .rightMouseUp,
             .mouseMoved,
             .leftMouseDragged,
             .rightMouseDragged,
             .mouseEntered,
             .mouseExited,
             .otherMouseDown,
             .otherMouseUp,
             .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}

private extension NSEvent {
    var mouseClickCountForAudit: Int {
        type.isMouseEventForAudit ? clickCount : 0
    }

    var mouseButtonNumberForAudit: Int {
        type.isMouseEventForAudit ? buttonNumber : 0
    }
}
