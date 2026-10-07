// Dev runner for the macOS conversation surface:
//   swift run CmuxConversationLabMac ws://127.0.0.1:4870/ws?conversation=group [light|dark] [control-fifo]
// With a control FIFO, each line is a lab command (type/send/top/bottom/scroll/
// rows/menu/tapback/reply/edit/react/escape/resize WxH/window); replies go to stdout.
import AppKit
import CmuxConversationMacUI

let arguments = CommandLine.arguments
let endpoint = URL(string: arguments.count > 1 ? arguments[1] : "ws://127.0.0.1:4870/ws?conversation=group")!
NSSetUncaughtExceptionHandler { exception in
    FileHandle.standardError.write("UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "?")\n\(exception.callStackSymbols.joined(separator: "\n"))\n".data(using: .utf8)!)
}
let app = NSApplication.shared
// Driven runs (a control FIFO) never activate: they must not take focus
// from whatever the person at the Mac is doing.
let driven = arguments.count > 3
app.setActivationPolicy(driven ? .prohibited : .regular)
if arguments.count > 2 {
    app.appearance = NSAppearance(named: arguments[2] == "light" ? .aqua : .darkAqua)
}
// Messages' menu bar (Edit > Reply/Tapback/Edit Last, Window > Next Conversation…).
MainActor.assumeIsolated { app.mainMenu = MacConversationLab.makeMainMenu() }
let controller = MainActor.assumeIsolated {
    MacConversationLab.treatsInactiveAsViewing = driven
    // Messages badges its Dock icon with the total unread count.
    MacConversationLab.onUnreadTotalChange = { total in
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }
    return MacConversationLab.open(endpoint: endpoint)
}
// The lab opens on the display named by CMUX_LAB_DISPLAY (default "LG HDR 4K"),
// never on the person's main working display.
do {
    MainActor.assumeIsolated {
        let name = ProcessInfo.processInfo.environment["CMUX_LAB_DISPLAY"] ?? "LG HDR 4K"
        if let screen = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }),
           let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "cmux.conversationLab" }) {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - window.frame.height - 40))
        }
    }
}

if arguments.count > 3 {
    let fifo = arguments[3]
    Thread.detachNewThread {
        // Opened read-write so the pipe never reports EOF between writers;
        // reading to EOF and reopening dropped lines from back-to-back writes.
        guard let handle = FileHandle(forUpdatingAtPath: fifo) else { return }
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { continue }
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            pending = Data(pending[pending.index(after: lastNewline)...])
            for line in String(decoding: complete, as: UTF8.self).split(separator: "\n").map(String.init) {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        let reply: String
                        if line.hasPrefix("resize ") {
                            let size = line.dropFirst(7).split(separator: "x").compactMap { Double($0) }
                            if size.count == 2, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "cmux.conversationLab" }) {
                                window.setContentSize(NSSize(width: size[0], height: size[1]))
                                reply = "ok"
                            } else {
                                reply = "error usage resize WxH"
                            }
                        } else if line.hasPrefix("select ") {
                            MacConversationLab.select(String(line.dropFirst(7)))
                            reply = "ok"
                        } else if line == "window" {
                            reply = "window \(NSApp.windows.first(where: { $0.identifier?.rawValue == "cmux.conversationLab" })?.windowNumber ?? 0)"
                        } else if line.hasPrefix("search") {
                            reply = "visible " + MacConversationLab.search(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)).joined(separator: ",")
                        } else if line.hasPrefix("filter ") {
                            reply = MacConversationLab.setFilter(String(line.dropFirst(7))) ? "ok" : "error usage filter all|unread"
                        } else if line == "list" {
                            let snapshot = MacConversationLab.listSnapshot()
                            let data = (try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])) ?? Data()
                            reply = String(decoding: data, as: UTF8.self)
                        } else if line.hasPrefix("listaction ") {
                            // listaction <togglePin|toggleUnread|toggleAlerts|delete> <id> [noconfirm]
                            let words = line.split(separator: " ").map(String.init)
                            if words.count >= 3, let action = MacConversationListAction(rawValue: words[1]) {
                                MacConversationLab.listAction(action, conversation: words[2], confirm: words.count < 4)
                                reply = "ok"
                            } else {
                                reply = "error usage listaction <action> <id> [noconfirm]"
                            }
                        } else if line.hasPrefix("movepin ") {
                            let words = line.split(separator: " ").map(String.init)
                            if words.count == 3, let index = Int(words[2]) {
                                MacConversationLab.movePin(words[1], to: index)
                                reply = "ok"
                            } else {
                                reply = "error usage movepin <id> <index>"
                            }
                        } else if line.hasPrefix("png ") || line.hasPrefix("sidebarpng ") {
                            let sidebarOnly = line.hasPrefix("sidebarpng ")
                            let path = String(line.split(separator: " ", maxSplits: 1)[1])
                            reply = MacConversationLab.renderPNG(to: path, sidebarOnly: sidebarOnly) ? "ok \(path)" : "error render"
                        } else if line == "sheet" {
                            reply = MacConversationLab.sheetSummary() ?? "none"
                        } else if line.hasPrefix("sheetpress ") {
                            reply = MacConversationLab.pressSheetButton(String(line.dropFirst(11))) ? "ok" : "error no button"
                        } else if line.hasPrefix("snapshot ") {
                            // Renders the lab window's layer tree to a PNG (no Screen Recording needed).
                            reply = labSnapshot(path: String(line.dropFirst(9)))
                        } else if line == "deactivate" {
                            app.deactivate()
                            reply = "ok"
                        } else if line.hasPrefix("appearance ") {
                            app.appearance = NSAppearance(named: line.hasSuffix("light") ? .aqua : .darkAqua)
                            reply = "ok"
                        } else if let input = MacConversationLab.labInput(line) {
                            // key/click/drag/rclick/copyprobe/kstate: synthesized AppKit input.
                            reply = input
                        } else {
                            reply = (MacConversationLab.selectedController ?? controller).labCommand(line)
                        }
                        print("\(line) -> \(reply)")
                        fflush(stdout)
                    }
                }
            }
        }
    }
}
@MainActor
func labSnapshot(path: String) -> String {
    guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "cmux.conversationLab" }),
          let root = window.contentView?.superview ?? window.contentView, let layer = root.layer else { return "error no window" }
    let scale = window.backingScaleFactor
    let size = root.bounds.size
    guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "error context" }
    context.scaleBy(x: scale, y: scale)
    if layer.isGeometryFlipped {
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
    }
    layer.render(in: context)
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "error image" }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil ? "ok" : "error write"
}

app.run()
