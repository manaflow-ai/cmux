// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxCUEngine
import Foundation

// cmux-cu-service [serve] [--socket PATH]   the engine on its per-user socket
// cmux-cu-service stdio                     one MCP session on stdin/stdout,
//                                           in this process (it must hold the grants)
// cmux-cu-service status | grant            read, or raise macOS prompts for, its grants
// cmux-cu-service mcp [--socket PATH] [--app PATH]
//                                           the agent-side MCP server: a byte
//                                           pump to the socket, launching the app

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first.flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "serve"
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}
let socket = EngineSocket(path: option("--socket") ?? EngineSocket.defaultPath)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cmux-cu-service: \(message)\n".utf8))
    exit(1)
}

switch mode {
case "mcp":
    let app = option("--app") ?? (NSHomeDirectory() as NSString).appendingPathComponent("Applications/cmux CU Engine.app")
    do {
        try SocketBridge(socket: socket, appPath: app).run()
    } catch {
        FileHandle.standardError.write(Data("cmux-cu-service: \(error)\n".utf8))
        exit(69)
    }
case "status", "grant":
    // `grant` raises macOS's own Accessibility and Screen Recording prompts
    // for this app (a person answers them in System Settings); `status` only reads.
    let prompt = mode == "grant"
    let ax = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    var screen = CGPreflightScreenCaptureAccess()
    if prompt, !screen { screen = CGRequestScreenCaptureAccess() }
    print("accessibility=\(ax ? "granted" : "missing") screen_recording=\(screen ? "granted" : "missing")")
    exit(ax && screen ? 0 : 3)
case "stdio":
    let connection = MCPConnection(engine: Engine(), input: .standardInput, output: .standardOutput)
    let done = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) { [connection, done] in
        await connection.serve()
        done.signal()
    }
    done.wait()
    exit(0)
case "serve":
    let engine = Engine()
    // No Dock icon and no menu bar: the engine never takes focus.
    NSApplication.shared.setActivationPolicy(.prohibited)
    Thread.detachNewThread { [socket, engine] in
        do {
            try socket.serve(engine: engine)
        } catch {
            fail("\(error)")
        }
    }
    RunLoop.main.run()
default:
    fail("unknown mode \(mode) (serve, stdio, mcp)")
}
