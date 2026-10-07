#if os(macOS) && DEBUG
import AppKit

/// Lab-only input synthesis: real NSEvents dispatched the way NSApplication
/// routes them (key equivalents to the window then the menu bar, keys to the
/// first responder, mouse tracking through the event queue), so a driven,
/// never-activated lab run exercises the same AppKit paths a person does.
extension MacConversationLab {
    private static var labWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "cmux.conversationLab" }
    }

    private static var split: MacConversationSplitController? {
        labWindow?.contentViewController as? MacConversationSplitController
    }

    /// Handles `key`, `click`, `drag`, `rclick`, `copyprobe` and `kstate`; nil for other verbs.
    public static func labInput(_ line: String) -> String? {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first, let window = labWindow else { return nil }
        let numbers = parts.dropFirst().compactMap { Double($0) }.map { CGFloat($0) }
        switch verb {
        case "key":
            guard parts.count == 2 else { return "error usage key <mods+key>" }
            return sendKey(parts[1], to: window)
        case "copyprobe":
            guard parts.count == 2 else { return "error usage copyprobe <mods+key>" }
            // Never leave the person's clipboard changed by a probe.
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            } ?? []
            pasteboard.clearContents()
            pasteboard.setString("<probe-empty>", forType: .string)
            let routed = sendKey(parts[1], to: window)
            let copied = pasteboard.string(forType: .string) ?? ""
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
            return "\(routed) copied \(copied.debugDescription)"
        case "click":
            guard numbers.count >= 2 else { return "error usage click x y [count]" }
            let count = numbers.count > 2 ? Int(numbers[2]) : 1
            for n in 1...max(1, count) { mouse(.leftMouseDown, path: [CGPoint(x: numbers[0], y: numbers[1])], clickCount: n, in: window) }
            return "ok"
        case "drag":
            guard numbers.count == 4 else { return "error usage drag x1 y1 x2 y2" }
            let from = CGPoint(x: numbers[0], y: numbers[1]), to = CGPoint(x: numbers[2], y: numbers[3])
            let path = (0...12).map { step -> CGPoint in
                let t = CGFloat(step) / 12
                return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            }
            mouse(.leftMouseDown, path: path, clickCount: 1, in: window)
            return "ok"
        case "rclick":
            guard numbers.count == 2, let content = window.contentView else { return "error usage rclick x y" }
            let location = windowPoint(CGPoint(x: numbers[0], y: numbers[1]), in: window)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let hit = content.superview?.hitTest(location) ?? content.hitTest(location) else { return "error no view" }
            var view: NSView? = hit
            while let current = view {
                if let menu = current.menu(for: event) {
                    menu.update()
                    let titles = menu.items.map { $0.isSeparatorItem ? "-" : ($0.isEnabled ? $0.title : "(\($0.title))") }
                    // The bubble keeps its pressed look only while a menu is open.
                    menu.delegate?.menuDidClose?(menu)
                    return "menu[\(String(describing: type(of: current)))] " + titles.joined(separator: "|")
                }
                view = current.superview
            }
            return "menu none (hit \(String(describing: type(of: hit))))"
        case "kstate":
            return state(window)
        case "bubble":
            // Top-left window rect of the newest visible bubble text containing the argument.
            let query = parts.dropFirst().joined(separator: " ")
            guard let controller = split?.selected?.controller, let content = window.contentView else { return "error no conversation" }
            for index in controller.rows.indices.reversed() {
                guard let model = controller.messageModel(at: index), model.message.text.contains(query),
                      let row = controller.rowView(at: index), !row.textLabel.isHidden else { continue }
                let rect = content.convert(row.textLabel.bounds, from: row.textLabel)
                let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
                return String(format: "bubble %.1f %.1f %.1f %.1f", rect.minX, top, rect.width, rect.height)
            }
            return "error no visible bubble"
        default:
            return nil
        }
    }

    private static func state(_ window: NSWindow) -> String {
        var fields: [String] = []
        let responder = window.firstResponder
        fields.append("fr=\(responder.map { String(describing: type(of: $0)) } ?? "nil")")
        if let text = responder as? MacBubbleTextView {
            let range = text.selectedRange()
            fields.append("textsel=\(range.location),\(range.length) \((text.string as NSString).substring(with: range).debugDescription)")
        }
        if let split {
            fields.append("conversation=\(split.selected?.id ?? "nil") listRow=\(split.sidebar.tableView.selectedRow)/\(split.sidebar.visibleIDs.joined(separator: ","))")
            if let controller = split.selected?.controller {
                let id = controller.keyboard.selectedRowID
                let text = controller.rows.compactMap { row -> String? in
                    if case let .message(model) = row, model.rowID == id { return model.message.text } else { return nil }
                }.first
                fields.append("selected=\(id ?? "nil") \(text.map { String($0.prefix(40)).debugDescription } ?? "")")
                fields.append("reply=\(controller.composer.isReplyMode) edit=\(controller.composer.isEditMode) picker=\(controller.replyFocus?.onKeyDown != nil && controller.replyFocus?.superview != nil)")
                fields.append("composer=\(controller.composer.text.debugDescription) times=\(controller.keyboard.showsTimes)")
            }
        }
        return fields.joined(separator: " ")
    }

    private static func windowPoint(_ point: CGPoint, in window: NSWindow) -> NSPoint {
        // Lab coordinates are top-left window-content points.
        NSPoint(x: point.x, y: (window.contentView?.bounds.height ?? window.frame.height) - point.y)
    }

    /// Posts the drag and release first, then delivers the press: AppKit's
    /// tracking loops (selection, drag-out, press-and-hold) read them back.
    private static func mouse(_ type: NSEvent.EventType, path: [CGPoint], clickCount: Int, in window: NSWindow) {
        let now = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ offset: TimeInterval) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: windowPoint(point, in: window), modifierFlags: [], timestamp: now + offset,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
        }
        guard let first = path.first, let last = path.last, let down = event(.leftMouseDown, first, 0) else { return }
        for (index, point) in path.dropFirst().enumerated() {
            if let drag = event(.leftMouseDragged, point, 0.01 * Double(index + 1)) { NSApp.postEvent(drag, atStart: false) }
        }
        if let up = event(.leftMouseUp, last, 0.01 * Double(path.count + 1)) { NSApp.postEvent(up, atStart: false) }
        window.sendEvent(down)
        // Drain anything the press's handler left unread.
        while let pending = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "tab": 48, "return": 36, "space": 49, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    private static func sendKey(_ spec: String, to window: NSWindow) -> String {
        var flags: NSEvent.ModifierFlags = []
        var key = ""
        for token in spec.lowercased().split(separator: "+").map(String.init) {
            switch token {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: key = token
            }
        }
        guard let code = keyCodes[key] else { return "error unknown key \(key)" }
        let special: [String: String] = [
            "tab": flags.contains(.shift) ? "\u{19}" : "\t", "return": "\r", "space": " ", "esc": "\u{1b}",
            "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "right": String(UnicodeScalar(NSRightArrowFunctionKey)!),
            "down": String(UnicodeScalar(NSDownArrowFunctionKey)!), "up": String(UnicodeScalar(NSUpArrowFunctionKey)!),
        ]
        let plain = special[key] ?? key
        let characters = flags.contains(.shift) && special[key] == nil ? plain.uppercased() : plain
        var eventFlags = flags
        if ["left", "right", "up", "down"].contains(key) { eventFlags.insert([.numericPad, .function]) }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: eventFlags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code) else { return "error event" }
        MacKeyboardNavigation.syntheticKeyDepth += 1
        defer { MacKeyboardNavigation.syntheticKeyDepth -= 1 }
        // NSApplication's order: key equivalents (window, then menu bar) before keyDown.
        if flags.contains(.command) || flags.contains(.control) {
            if window.performKeyEquivalent(with: event) { return "keyEquivalent" }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return "menu" }
        }
        window.sendEvent(event)
        return "keyDown"
    }
}
#endif
