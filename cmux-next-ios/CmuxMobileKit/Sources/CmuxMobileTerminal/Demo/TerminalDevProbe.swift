// DEBUG and Demo builds only; never compiled into Production.
#if DEBUG && os(iOS)
import Foundation
import OSLog
import QuartzCore

/// Rig measurement tools for one terminal screen, on with `-CmuxMobileTermProbe`
/// (ACCEPTANCE.md G-08 and G-09; `verify/termqa/termprobe.py` reads them):
///
/// - **Echo probe (M-ECHO):** each printable byte sent is stamped when it
///   leaves; the echo is found in the session output (`TerminalEchoMatcher`)
///   and stamped at the first frame presented after Ghostty parsed it. Each
///   sample goes to `Documents/termprobe/echo.jsonl` and the `termprobe` log.
/// - **Text export (M-INTEG):** a Darwin notification
///   `dev.cmux.mobile.termprobe.export` (on a simulator:
///   `xcrun simctl spawn UDID notifyutil -p dev.cmux.mobile.termprobe.export`)
///   writes every open terminal's whole text (scrollback and screen, soft
///   wraps joined) to `Documents/termprobe/<title>.txt`, then posts
///   `dev.cmux.mobile.termprobe.exported`.
@MainActor
final class TerminalDevProbe {
    static let isEnabled = CommandLine.arguments.contains("-CmuxMobileTermProbe")
    private static let log = Logger(subsystem: "dev.cmux.mobile", category: "termprobe")
    static let exportName = "dev.cmux.mobile.termprobe.export"
    static let exportedName = "dev.cmux.mobile.termprobe.exported"

    private let title: () -> String
    private let text: () -> String?
    private var matcher = TerminalEchoMatcher()
    /// Echoes in the batch with Ghostty, then waiting for a presented frame.
    private var inFlight: [TerminalEchoMatcher.Key] = []
    private var awaitingPresent: [TerminalEchoMatcher.Key] = []
    private var samples: [Double] = []
    private static var live: [ObjectIdentifier: () -> Void] = [:]
    private static var observing = false

    init(title: @escaping () -> String, text: @escaping () -> String?) {
        self.title = title
        self.text = text
        Self.live[ObjectIdentifier(self)] = { [weak self] in self?.export() }
        Self.observe()
    }

    isolated deinit { Self.live[ObjectIdentifier(self)] = nil }

    func sent(_ data: Data) { matcher.sent(data, at: CACurrentMediaTime()) }

    /// A batch is handed to Ghostty.
    func fed(_ data: Data) { inFlight += matcher.output(data, at: CACurrentMediaTime()) }

    /// Ghostty parsed the batch.
    func processed() {
        awaitingPresent += inFlight
        inFlight.removeAll()
    }

    /// A frame was presented.
    func presented() {
        guard !awaitingPresent.isEmpty else { return }
        let now = CACurrentMediaTime()
        let name = title()
        var lines = ""
        for key in awaitingPresent {
            let ms = (now - key.sentAt) * 1000
            samples.append(ms)
            Self.log.notice("echo \(name, privacy: .public) byte=\(key.byte, privacy: .public) ms=\(ms, format: .fixed(precision: 1), privacy: .public)")
            lines += String(format: "{\"t\":%.3f,\"terminal\":\"%@\",\"byte\":%d,\"ms\":%.2f}\n",
                            Date().timeIntervalSince1970, Self.jsonEscaped(name), key.byte, ms)
        }
        awaitingPresent.removeAll()
        Self.append(lines, to: "echo.jsonl")
    }

    private func export() {
        let name = title()
        guard let body = text() else { return }
        let stats = TerminalEchoStats(samples)
        let file = Self.safeName(name) + ".txt"
        Self.write(body, to: file)
        Self.log.notice("export \(name, privacy: .public) -> \(file, privacy: .public) bytes=\(body.utf8.count, privacy: .public) echo n=\(stats.n, privacy: .public) p50=\(stats.p50, privacy: .public) p95=\(stats.p95, privacy: .public) lost=\(self.matcher.lost, privacy: .public)")
    }

    private static func observe() {
        guard !observing else { return }
        observing = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, nil, { _, _, _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for export in TerminalDevProbe.live.values { export() }
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                         CFNotificationName(TerminalDevProbe.exportedName as CFString), nil, nil, true)
                }
            }
        }, exportName as CFString, nil, .deliverImmediately)
    }

    private static var directory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("termprobe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ text: String, to name: String) {
        guard let url = directory?.appendingPathComponent(name) else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func append(_ text: String, to name: String) {
        guard let url = directory?.appendingPathComponent(name) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    private static func safeName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
#endif
