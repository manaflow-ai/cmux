// InputProbe: a window that shows (large) and logs (JSONL) every mouse, scroll
// and key event it receives, for live checks of a screen-sharing viewer's input.
// Build on the host Mac: swiftc -O InputProbe.swift -o InputProbe
// Run: InputProbe <log path>
import AppKit

final class ProbeView: NSView {
    var lines: [String] = []
    let log: FileHandle?
    var dragCount = 0

    init(frame: NSRect, logPath: String) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        log = FileHandle(forWritingAtPath: logPath)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func mods(_ e: NSEvent) -> String {
        var s = ""
        if e.modifierFlags.contains(.control) { s += "⌃" }
        if e.modifierFlags.contains(.option) { s += "⌥" }
        if e.modifierFlags.contains(.shift) { s += "⇧" }
        if e.modifierFlags.contains(.command) { s += "⌘" }
        return s
    }

    func record(_ kind: String, _ e: NSEvent, _ extra: [String: Any] = [:]) {
        let p = convert(e.locationInWindow, from: nil)
        var entry: [String: Any] = ["t": Date().timeIntervalSince1970, "kind": kind, "mods": mods(e), "x": Int(p.x), "y": Int(p.y)]
        entry.merge(extra) { a, _ in a }
        if let data = try? JSONSerialization.data(withJSONObject: entry), let log {
            log.write(data); log.write(Data("\n".utf8))
        }
        let detail = extra.keys.sorted().map { "\($0)=\(extra[$0]!)" }.joined(separator: " ")
        lines.append("\(mods(e))\(kind) @\(Int(p.x)),\(Int(p.y)) \(detail)")
        if lines.count > 14 { lines.removeFirst(lines.count - 14) }
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) { dragCount = 0; record("left-down", e, ["clicks": e.clickCount]) }
    override func mouseUp(with e: NSEvent) { record("left-up", e, ["clicks": e.clickCount, "drags": dragCount]) }
    override func mouseDragged(with e: NSEvent) { dragCount += 1; if dragCount % 10 == 1 { record("left-drag", e) } }
    override func rightMouseDown(with e: NSEvent) { record("right-down", e, ["clicks": e.clickCount]) }
    override func rightMouseUp(with e: NSEvent) { record("right-up", e) }
    override func otherMouseDown(with e: NSEvent) { record("middle-down", e) }
    override func otherMouseDragged(with e: NSEvent) { record("middle-drag", e) }
    override func scrollWheel(with e: NSEvent) {
        record("scroll", e, ["dx": String(format: "%.1f", e.scrollingDeltaX), "dy": String(format: "%.1f", e.scrollingDeltaY),
                             "precise": e.hasPreciseScrollingDeltas])
    }
    override func keyDown(with e: NSEvent) {
        record("key", e, ["chars": e.charactersIgnoringModifiers ?? "", "code": e.keyCode])
    }
    override func magnify(with e: NSEvent) { record("magnify", e, ["m": String(format: "%.2f", e.magnification)]) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.08, green: 0.1, blue: 0.16, alpha: 1).setFill()
        bounds.fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.systemYellow]
        ("InputProbe: what this Mac received" as NSString).draw(at: NSPoint(x: 24, y: 18), withAttributes: title)
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor.white]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 24, y: 76 + CGFloat(i) * 36), withAttributes: body)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let logPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/inputprobe.jsonl"
let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
// Centered, so the middle of the shared screen (where the live test taps) falls inside it.
let size = NSSize(width: min(1200, screen.width - 80), height: min(760, screen.height - 160))
let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
window.title = "InputProbe"
let view = ProbeView(frame: NSRect(origin: .zero, size: frame.size), logPath: logPath)
window.contentView = view
window.level = .floating
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(view)
app.activate(ignoringOtherApps: true)
app.run()
