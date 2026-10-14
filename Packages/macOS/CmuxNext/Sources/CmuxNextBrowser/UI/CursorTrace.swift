#if DEBUG
public import AppKit
import ObjectiveC

/// DEBUG only, with `CMUX_NEXT_CURSOR_TRACE=1`: every `NSCursor.set` (with
/// the pointer, the key window and the calling frames) and every pointer
/// event the app dispatches (with its window and that window's first
/// responder), written to stderr. It tells which code set the cursor last
/// over the browser toolbar.
extension ArrowCursorView {
    /// One pointer event before the app dispatches it (`CmuxApplication.sendEvent`).
    public static func traceEvent(_ event: NSEvent) { CursorTrace.event(event) }
}

enum CursorTrace {
    nonisolated static let enabled = ProcessInfo.processInfo.environment["CMUX_NEXT_CURSOR_TRACE"] == "1"
    nonisolated(unsafe) private static var original: IMP?

    @MainActor static func install() {
        guard enabled, original == nil, let method = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set)) else { return }
        let known = [(ObjectIdentifier(NSCursor.iBeam), "iBeam"), (ObjectIdentifier(NSCursor.arrow), "arrow"),
                     (ObjectIdentifier(NSCursor.pointingHand), "hand")]
        let block: @convention(block) @Sendable (NSCursor) -> Void = { cursor in
            let id = ObjectIdentifier(cursor)
            let name = known.first { $0.0 == id }?.1 ?? "other"
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    // The first frames are this block and its thunks.
                    let frames = Thread.callStackSymbols.dropFirst(8).prefix(14).map(frame)
                    let key = NSApp.keyWindow
                    write("cursor.set \(name) at \(point(NSEvent.mouseLocation)) key \(key.map { String(describing: type(of: $0)) } ?? "-")"
                          + " responder \(key?.firstResponder.map { String(describing: type(of: $0)) } ?? "-") by \(frames.joined(separator: " < "))")
                }
            } else {
                write("cursor.set off the main thread")
            }
            typealias SetFunction = @convention(c) (NSCursor, Selector) -> Void
            if let original { unsafeBitCast(original, to: SetFunction.self)(cursor, #selector(NSCursor.set)) }
        }
        original = method_setImplementation(method, imp_implementationWithBlock(block))
        write("cursor trace installed")
    }

    /// "Module:symbol" of one `callStackSymbols` line ("N  Module Name  0xADDR symbol + offset").
    nonisolated private static func frame(_ line: String) -> String {
        guard let address = line.range(of: " 0x") else { return line }
        let module = line[..<address.lowerBound].drop { $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
        var symbol = line[address.upperBound...].drop { $0.isHexDigit }.trimmingCharacters(in: .whitespaces)
        if let plus = symbol.range(of: " + ", options: .backwards) { symbol = String(symbol[..<plus.lowerBound]) }
        return "\(module):\(symbol)"
    }

    /// One pointer event before the app dispatches it. Reads no tracking area, and
    /// `locationInWindow` only of moves, drags and presses.
    @MainActor static func event(_ event: NSEvent) {
        guard enabled else { return }
        let kind: String
        var hasLocation = true
        switch event.type {
        case .mouseMoved: kind = "moved"
        case .leftMouseDragged: kind = "dragged"
        case .leftMouseDown: kind = "down"
        case .leftMouseUp: kind = "up"
        case .mouseEntered: kind = "entered"; hasLocation = false
        case .mouseExited: kind = "exited"; hasLocation = false
        case .cursorUpdate: kind = "cursorUpdate"; hasLocation = false
        default: return
        }
        let window = event.window
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
        write("event \(kind) window \(window.map { String(describing: type(of: $0)) } ?? "-")#\(event.windowNumber) "
              + "key \(window?.isKeyWindow ?? false) child \(window?.parent != nil) "
              + "in-window \(hasLocation ? point(event.locationInWindow) : "-") screen \(point(NSEvent.mouseLocation)) "
              + "responder \(responder) key-window \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "-")")
    }

    /// `String(format:)`, not `Int(_:)`: a point of a move may be far out (`Int` traps on a non-finite value).
    nonisolated private static func point(_ p: NSPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }

    nonisolated static func write(_ line: String) {
        FileHandle.standardError.write(Data("[cursor-trace \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(line)\n".utf8))
    }
}
#endif
