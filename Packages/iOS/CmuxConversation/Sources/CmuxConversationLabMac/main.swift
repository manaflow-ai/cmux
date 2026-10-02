// Dev runner for the macOS conversation surface:
//   swift run CmuxConversationLabMac ws://127.0.0.1:4870/ws?conversation=group [light|dark] [control-fifo]
// With a control FIFO, each line is a lab command (type/send/top/bottom/scroll/
// rows/menu/tapback/reply/edit/react/escape/resize WxH/window); replies go to stdout.
import AppKit
import CmuxConversationMacUI

let arguments = CommandLine.arguments
let endpoint = URL(string: arguments.count > 1 ? arguments[1] : "ws://127.0.0.1:4870/ws?conversation=group")!
let app = NSApplication.shared
app.setActivationPolicy(.regular)
if arguments.count > 2 {
    app.appearance = NSAppearance(named: arguments[2] == "light" ? .aqua : .darkAqua)
}
let controller = MainActor.assumeIsolated { MacConversationLab.open(endpoint: endpoint) }

if arguments.count > 3 {
    let fifo = arguments[3]
    Thread.detachNewThread {
        while true {
            guard let handle = FileHandle(forReadingAtPath: fifo) else { return }
            let data = handle.readDataToEndOfFile()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) {
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
                        } else if line == "deactivate" {
                            app.deactivate()
                            reply = "ok"
                        } else if line.hasPrefix("appearance ") {
                            app.appearance = NSAppearance(named: line.hasSuffix("light") ? .aqua : .darkAqua)
                            reply = "ok"
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
app.run()
