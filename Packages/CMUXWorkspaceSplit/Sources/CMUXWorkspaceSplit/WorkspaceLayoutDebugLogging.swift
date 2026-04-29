import AppKit
import Foundation

#if DEBUG
enum WorkspaceLayoutDebugCounters {
    private(set) static var arrangedSubviewUnderflowCount: Int = 0

    static func reset() {
        arrangedSubviewUnderflowCount = 0
    }

    static func recordArrangedSubviewUnderflow() {
        arrangedSubviewUnderflowCount += 1
    }
}
#else
enum WorkspaceLayoutDebugCounters {
    static let arrangedSubviewUnderflowCount: Int = 0

    static func reset() {}
    static func recordArrangedSubviewUnderflow() {}
}
#endif

#if DEBUG
let cmuxDebugLogLock = NSLock()

private func workspaceLayoutAppendDebugLog(path: String, data: Data) {
    if let handle = FileHandle(forWritingAtPath: path) {
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil else { return }
        try? handle.write(contentsOf: data)
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
#endif

func dlog(_ message: String) {
    NSLog("%@", message)
#if DEBUG
    guard let rawLogPath = ProcessInfo.processInfo.environment["CMUX_DEBUG_LOG"],
          !rawLogPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
    }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) \(message)\n"
    let data = Data(line.utf8)

    cmuxDebugLogLock.lock()
    defer { cmuxDebugLogLock.unlock() }

    workspaceLayoutAppendDebugLog(path: rawLogPath, data: data)
#endif
}

#if DEBUG
func startupLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    let logPath = "/tmp/cmux-startup-debug.log"
    workspaceLayoutAppendDebugLog(path: logPath, data: Data(line.utf8))
}
#else
func startupLog(_ message: String) {
    _ = message
}
#endif

#if DEBUG
let cmuxLatencyLogPath = "/tmp/cmux-key-latency-debug.log"
let cmuxLatencyLogLock = NSLock()
var cmuxLatencyLogSequence: UInt64 = 0

func latencyLog(_ name: String, data: [String: String] = [:]) {
    let ts = ISO8601DateFormatter().string(from: Date())
    cmuxLatencyLogLock.lock()
    cmuxLatencyLogSequence &+= 1
    let seq = cmuxLatencyLogSequence
    cmuxLatencyLogLock.unlock()

    let monoMs = Int((ProcessInfo.processInfo.systemUptime * 1000.0).rounded())
    let payload = data
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: " ")
    let suffix = payload.isEmpty ? "" : " " + payload
    let line = "[\(ts)] seq=\(seq) mono_ms=\(monoMs) event=\(name)\(suffix)\n"

    cmuxLatencyLogLock.lock()
    defer { cmuxLatencyLogLock.unlock() }
    workspaceLayoutAppendDebugLog(path: cmuxLatencyLogPath, data: Data(line.utf8))
}

func isDebugCmdD(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return flags == [.command] && (event.charactersIgnoringModifiers ?? "").lowercased() == "d"
}

func isDebugCtrlD(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return flags == [.control] && (event.charactersIgnoringModifiers ?? "").lowercased() == "d"
}
#else
func latencyLog(_ name: String, data: [String: String] = [:]) {
    _ = name
    _ = data
}

func isDebugCmdD(_ event: NSEvent) -> Bool {
    _ = event
    return false
}

func isDebugCtrlD(_ event: NSEvent) -> Bool {
    _ = event
    return false
}
#endif
