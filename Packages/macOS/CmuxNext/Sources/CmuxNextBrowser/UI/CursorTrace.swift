#if DEBUG
import AppKit
import ObjectiveC

/// DEBUG only, with `CMUX_NEXT_CURSOR_TRACE=1`: every `NSCursor.set` (with
/// the pointer and the calling frames) and every pointer event the app
/// dispatches (with its window and that window's first responder), written to
/// stderr. It tells which code set the cursor last over the browser toolbar.
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
                    let frames = Thread.callStackSymbols.dropFirst(1).prefix(10).map { line -> String in
                        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                        return parts.count > 3 ? "\(parts[1]):\(parts[3])" : line
                    }
                    write("cursor.set \(name) at \(point(NSEvent.mouseLocation)) by \(frames.joined(separator: " < "))")
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

    /// One pointer event before the app dispatches it. Reads no tracking area.
    @MainActor static func event(_ event: NSEvent) {
        guard enabled else { return }
        let kind: String
        switch event.type {
        case .mouseMoved: kind = "moved"
        case .mouseEntered: kind = "entered"
        case .mouseExited: kind = "exited"
        case .cursorUpdate: kind = "cursorUpdate"
        case .leftMouseDragged: kind = "dragged"
        case .leftMouseDown: kind = "down"
        case .leftMouseUp: kind = "up"
        default: return
        }
        let window = event.window
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"
        write("event \(kind) window \(window.map { String(describing: type(of: $0)) } ?? "-")#\(event.windowNumber) "
              + "key \(window?.isKeyWindow ?? false) child \(window?.parent != nil) in-window \(point(event.locationInWindow)) "
              + "screen \(point(NSEvent.mouseLocation)) responder \(responder) key-window \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "-")")
    }

    nonisolated private static func point(_ p: NSPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }

    nonisolated private static func write(_ line: String) {
        FileHandle.standardError.write(Data("[cursor-trace \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(line)\n".utf8))
    }
}
#endif
