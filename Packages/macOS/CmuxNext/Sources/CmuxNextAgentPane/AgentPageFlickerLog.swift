public import AppKit
import CmuxNextCompat
import Foundation
import os

nonisolated private let flickerLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.flicker-log")

/// An always-on record, with no UI, of what can make an agent page flash, so a flash Leo mentions can
/// be matched to its time (Leo, 2026-11-04: "it's because of an entire re-render of the thing ... a
/// flicker across nearly the full screen"). One JSON object per line, each with `at` in UTC:
///
/// - `web-content-ended`: the page's WebContent process ended (``AgentPageTerminations``).
/// - `navigation`: the pane's main frame committed a document (a load or a reload).
/// - `window-occlusion`: a window became visible or occluded.
/// - From the page (`diag.flicker`, webviews `acpmux/flickerLog.ts`): `page-load` (its navigation
///   type), `visibility` (the document's visibility), `transcript-mount` (the transcript's root
///   mounted; `n` over 1 is a remount) and `long-frame` (a frame over 100 ms while visible).
///
/// The file is a two-file ring under the app's state root:
/// `<Application Support>/<bundle id>/diagnostics/agent-page-flicker.ndjson`, which becomes
/// `agent-page-flicker.1.ndjson` when a write would take it past ``maximumBytes``. Nothing in a line is the
/// person's text: a page name (`chat:<session>` or `new-tab`), a pid, numbers and short words.
/// Writes run on a utility queue, never the main thread: a caller's turn only builds the line.
///
/// The composition root makes the app's one (``forAppRun()``) and hands it to every pane through
/// ``AgentPaneShared/flickerLog``; a pane without one (tests, tools) writes nothing.
@MainActor public final class AgentPageFlickerLog {
    nonisolated static let fileName = "agent-page-flicker.ndjson"
    nonisolated static let olderName = "agent-page-flicker.1.ndjson"
    nonisolated static let maximumBytes = 256 * 1024
    /// The page's method; answered in ``AgentPaneBridge`` before ``AgentPaneRequest``, never logged.
    nonisolated static let method = "diag.flicker"
    /// The kinds a page may write, and the most events one call carries.
    nonisolated static let pageKinds: Set<String> = ["page-load", "visibility", "transcript-mount", "long-frame"]
    nonisolated static let maximumPageEvents = 32

    /// The app run's ring, for the composition root to make once; nil outside an app bundle
    /// (package tests, tools), so they never write it.
    public nonisolated static func forAppRun() -> AgentPageFlickerLog? {
        guard Bundle.main.bundleURL.pathExtension == "app", let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return AgentPageFlickerLog(directory: support.appending(path: bundle).appending(path: "diagnostics", directoryHint: .isDirectory))
    }

    nonisolated let directory: URL
    private nonisolated let queue = DispatchQueue(label: "com.cmuxterm.app.next.agent-page.flicker-log", qos: .utility)
    /// Whether a pane asked for window occlusion lines (``watchWindows()``).
    private(set) var watchingWindows = false

    nonisolated init(directory: URL) {
        self.directory = directory
    }

    nonisolated var url: URL { directory.appending(path: Self.fileName) }

    /// Appends one line: `fields` with `at` (UTC, milliseconds) first.
    nonisolated func record(_ kind: String, at date: Date = Date(), _ fields: [String: Any] = [:]) {
        guard let line = Self.line(kind: kind, at: date, fields: fields) else { return }
        append([line])
    }

    /// The page's events (`{events: [{kind, at, ...}]}`) for the pane showing `page`: only known
    /// kinds and short scalar fields, at most ``maximumPageEvents``.
    nonisolated func recordPage(_ params: [String: Any]?, page: String, pid: Int32) {
        let lines = Self.pageLines(params, page: page, pid: pid)
        if !lines.isEmpty { append(lines) }
    }

    /// A pane's page name in a line: `chat:<session>`, or `new-tab`.
    static func pageName(_ view: AgentPaneView) -> String {
        view.model.sessionId.map { "chat:\($0)" } ?? "new-tab"
    }

    /// Waits for every queued write (tests).
    nonisolated func flush() { queue.sync {} }

    nonisolated static func pageLines(_ params: [String: Any]?, page: String, pid: Int32) -> [Data] {
        guard let events = params?["events"] as? [Any] else { return [] }
        return events.prefix(maximumPageEvents).compactMap { item -> Data? in
            guard let event = item as? [String: Any], let kind = event["kind"] as? String, pageKinds.contains(kind) else { return nil }
            let at = (event["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()
            var fields: [String: Any] = ["page": page, "from": "page"]
            if pid != 0 { fields["pid"] = Int(pid) }
            for (key, value) in event where !["kind", "at", "page", "pid", "from"].contains(key) {
                guard key.count <= 16 else { continue }
                if let text = value as? String, text.count <= 32 {
                    fields[key] = text
                } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    fields[key] = (number.doubleValue * 10).rounded() / 10
                } else if let flag = value as? Bool {
                    fields[key] = flag
                }
            }
            return line(kind: kind, at: at, fields: fields)
        }
    }

    nonisolated static func line(kind: String, at date: Date, fields: [String: Any]) -> Data? {
        var object = fields
        object["kind"] = kind
        object["at"] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }

    private nonisolated func append(_ lines: [Data]) {
        let directory = directory, url = url, older = directory.appending(path: Self.olderName)
        queue.async {
            do {
                try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.checked.fileExists(atPath: url.path) {
                    _ = FileManager.checked.createFile(atPath: url.path, contents: nil)
                }
                // The bound holds after the write: lines that would take the file past it start a
                // new one, and the full one becomes the older half of the ring.
                let added = lines.reduce(Data(), +)
                let handle = try FileHandle(forWritingTo: url)
                let size = try handle.seekToEnd()
                if size > 0, size + UInt64(added.count) > UInt64(Self.maximumBytes) {
                    try handle.close()
                    try? FileManager.checked.removeItem(at: older)
                    try FileManager.checked.moveItem(at: url, to: older)
                    _ = FileManager.checked.createFile(atPath: url.path, contents: added)
                    return
                }
                try handle.write(contentsOf: added)
                try handle.close()
            } catch {
                flickerLogger.error("agent page flicker log write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Records every window's occlusion flip from now on (each agent pane calls it; the first turns it on).
    /// The app's one window occlusion observer (`SurfaceInvariantMonitor`) hands each flip to
    /// ``recordOcclusion(of:)``; the log keeps no observer of its own.
    func watchWindows() {
        watchingWindows = true
    }

    /// One `window-occlusion` line for `window`'s flip, once a pane asked for them.
    public func recordOcclusion(of window: NSWindow) {
        guard watchingWindows else { return }
        record("window-occlusion", [
            "window": window.windowNumber,
            "visible": window.occlusionState.contains(.visible),
            "type": String(describing: type(of: window)),
        ])
    }
}
