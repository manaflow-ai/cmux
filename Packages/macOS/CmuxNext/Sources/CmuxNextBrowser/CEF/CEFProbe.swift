// PROBE (scratch, never lands): a timed log of key-window changes and Chromium focus calls around Cmd-N.
import AppKit

@MainActor public enum CEFProbe {
    public static var log: [String] { CEFRuntime.shared.probeLog }

    /// Wall-clock ms mod 100000, the page trace's clock (performance.timeOrigin + now).
    public static func stamp() -> Int { Int(Date().timeIntervalSince1970 * 1000) % 100_000 }

    public static func note(_ text: String) {
        CEFRuntime.shared.probeLog.append("\(stamp()) \(text)")
        if log.count > 160 { CEFRuntime.shared.probeLog.removeFirst(log.count - 160) }
    }

    public static func name(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }
        return "\(type(of: window))#\(UInt(bitPattern: ObjectIdentifier(window).hashValue) % 10_000)\(window.isVisible ? "" : "(hidden)")"
    }

    /// The shell window's key change, with who called it.
    public static func keyChange(_ window: NSWindow, _ word: String) {
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(30).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined() }.joined(separator: " < ")
        note("\(word) \(name(window)) key=\(name(NSApp.keyWindow)) \(stack)")
    }
}
