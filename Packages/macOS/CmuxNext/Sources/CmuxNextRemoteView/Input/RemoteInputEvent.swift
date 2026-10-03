import Foundation

/// One viewer input event. Mirrors cmux-rd-proto `InputEvent` field for
/// field, so the App encodes it without a mapping table.
public nonisolated enum RemoteInputEvent: Sendable, Hashable {
    /// A physical key by USB HID usage (`page << 16 | id`, keyboard page
    /// 0x07), independent of the viewer's keyboard layout.
    case key(usage: UInt32, down: Bool)
    /// Absolute pointer position in stream pixels.
    case pointer(x: Int32, y: Int32)
    case button(RemoteMouseButton, down: Bool)
    /// Hundredths of a line, or of a point when `precise`.
    case scroll(dx: Int32, dy: Int32, precise: Bool)
    /// IME-committed text. At most `maxTextBytes` UTF-8 bytes per event.
    case text(String)

    /// cmux-rd-proto `MAX_TEXT_BYTES`.
    public static let maxTextBytes = 256

    /// `text` split into events that each fit `maxTextBytes`, cut on
    /// character boundaries.
    public static func textEvents(_ text: String) -> [RemoteInputEvent] {
        var events: [RemoteInputEvent] = []
        var chunk = ""
        var chunkBytes = 0
        for character in text {
            let bytes = character.utf8.count
            if chunkBytes + bytes > maxTextBytes, !chunk.isEmpty {
                events.append(.text(chunk))
                chunk = ""
                chunkBytes = 0
            }
            chunk.append(character)
            chunkBytes += bytes
        }
        if !chunk.isEmpty { events.append(.text(chunk)) }
        return events
    }
}

/// Mouse buttons on the wire. Numbers follow the X11 core convention the
/// Linux host injects with (1 left, 2 middle, 3 right, 8 back, 9 forward);
/// other hosts map from these.
public nonisolated enum RemoteMouseButton: UInt8, Sendable, Hashable, CaseIterable {
    case left = 1
    case middle = 2
    case right = 3
    case back = 8
    case forward = 9

    /// AppKit's `NSEvent.buttonNumber` (0 left, 1 right, 2 middle, 3 back, 4 forward).
    public init?(appKitButtonNumber: Int) {
        switch appKitButtonNumber {
        case 0: self = .left
        case 1: self = .right
        case 2: self = .middle
        case 3: self = .back
        case 4: self = .forward
        default: return nil
        }
    }
}

/// Where captured input goes. The App sends it on the session's input
/// channel (unreliable datagrams with redundancy, cmux-rd-core `input`).
/// Called on the main actor, in event order.
@MainActor
public protocol RemoteViewInputSink: AnyObject {
    func send(_ event: RemoteInputEvent)
}
