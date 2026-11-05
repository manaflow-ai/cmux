import AppKit
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
/// `agent-page-flicker.1.ndjson` once it passes ``maximumBytes``. Nothing in a line is the
/// person's text: a page name (`chat:<session>` or `new-tab`), a pid, numbers and short words.
/// Writes run on a utility queue, never the main thread.
nonisolated final class AgentPageFlickerLog: Sendable {
    static let fileName = "agent-page-flicker.ndjson"
    static let olderName = "agent-page-flicker.1.ndjson"
    static let maximumBytes = 256 * 1024
    /// The page's method; answered in ``AgentPaneBridge`` before ``AgentPaneRequest``, never logged.
    static let method = "diag.flicker"
    /// The kinds a page may write, and the most events one call carries.
    static let pageKinds: Set<String> = ["page-load", "visibility", "transcript-mount", "long-frame"]
    static let maximumPageEvents = 32

    /// The app's ring; nil outside an app bundle (package tests, tools), so they never write it.
    static let shared: AgentPageFlickerLog? = {
        guard Bundle.main.bundleURL.pathExtension == "app", let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return AgentPageFlickerLog(directory: support.appending(path: bundle).appending(path: "diagnostics", directoryHint: .isDirectory))
    }()

    let directory: URL
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.agent-page.flicker-log", qos: .utility)

    init(directory: URL) {
        self.directory = directory
    }

    var url: URL { directory.appending(path: Self.fileName) }

    /// Appends one line: `fields` with `at` (UTC, milliseconds) first.
    func record(_ kind: String, at date: Date = Date(), _ fields: [String: Any] = [:]) {
        guard let line = Self.line(kind: kind, at: date, fields: fields) else { return }
        append([line])
    }

    /// The page's events (`{events: [{kind, at, ...}]}`) for the pane showing `page`: only known
    /// kinds and short scalar fields, at most ``maximumPageEvents``.
    func recordPage(_ params: [String: Any]?, page: String, pid: Int32) {
        let lines = Self.pageLines(params, page: page, pid: pid)
        if !lines.isEmpty { append(lines) }
    }

    /// A pane's page name in a line: `chat:<session>`, or `new-tab`.
    @MainActor static func pageName(_ view: AgentPaneView) -> String {
        view.model.sessionId.map { "chat:\($0)" } ?? "new-tab"
    }

    /// Waits for every queued write (tests).
    func flush() { queue.sync {} }

    static func pageLines(_ params: [String: Any]?, page: String, pid: Int32) -> [Data] {
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

    static func line(kind: String, at date: Date, fields: [String: Any]) -> Data? {
        var object = fields
        object["kind"] = kind
        object["at"] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        data.append(0x0A)
        return data
    }

    private func append(_ lines: [Data]) {
        let directory = directory, url = url, older = directory.appending(path: Self.olderName)
        queue.async {
            do {
                try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.checked.fileExists(atPath: url.path) {
                    _ = FileManager.checked.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                let size = try handle.seekToEnd()
                if size > UInt64(Self.maximumBytes) {
                    try handle.close()
                    try? FileManager.checked.removeItem(at: older)
                    try FileManager.checked.moveItem(at: url, to: older)
                    _ = FileManager.checked.createFile(atPath: url.path, contents: lines.reduce(Data(), +))
                    return
                }
                for line in lines { try handle.write(contentsOf: line) }
                try handle.close()
            } catch {
                flickerLogger.error("agent page flicker log write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Records every window's occlusion flip, once per app run (the first agent pane calls it).
    @MainActor static func watchWindows() {
        guard occlusion == nil, let log = shared else { return }
        occlusion = MainActorObservation(NSWindow.didChangeOcclusionStateNotification, read: { $0.object as? NSWindow }) { window in
            guard let window else { return }
            log.record("window-occlusion", [
                "window": window.windowNumber,
                "visible": window.occlusionState.contains(.visible),
                "type": String(describing: type(of: window)),
            ])
        }
    }

    /// App-wide for the app run.
    @MainActor private static var occlusion: MainActorObservation?
}
