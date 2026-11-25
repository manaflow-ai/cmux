#if os(iOS)
import Foundation
import Observation
import QuartzCore
import SwiftUI
import UIKit

#if DEBUG
/// `CMUX_MOBILE_LOAD_PROBE=1` (DEBUG): what each presented frame showed while a page loads, for
/// `LoadShiftsUITests` (Leo, 2026-11-24: "the loading has layout shifts and placeholder states").
/// Counted once per display frame, so a row that moved and came back between two samples of the
/// test's accessibility snapshot still counts:
/// - `placeholderFrames`: frames with a loading placeholder on screen (`placeholder(_:shown:)`).
/// - `shiftFrames`: frames where a row already drawn in the frame before, in a list that reports
///   its rows (`watch`), moved or resized by more than 1 pt while nobody scrolled it.
/// - `lastChangeEpochMs`: when a frame last differed from the one before it (a row came, went,
///   moved, or a placeholder came or went), wall clock, so the test's own clock can subtract.
/// The counters are cumulative for the process; the test reads them before and after each action.
/// One JSON object in a nearly transparent label, `debug.load-probe`.
///
/// `CMUX_MOBILE_SEND_TRACE=1` (with the probe on) also writes `Documents/send-trace.txt` for
/// `SnappySendBenchUITests` (Leo, 2026-11-25: "when you press enter, the stuff should just start
/// playing. we dont need to wait/get blocked by anything on rendering."): for each list watched
/// with a `role`, one line per display frame whose rows changed,
/// `t=<CACurrentMediaTime> v=<list> off=<contentOffset.y> rows=<id>|<role>|<content minY>|<height>;...`
/// (the visible rows, in content coordinates, so following the bottom is not a move), and the
/// app's own marks as `t=<...> ev=<name>` (`event`). The time is the display link's callback,
/// so a row in a line was laid out for the frame that callback precedes (within one frame).
@MainActor
@Observable
public final class LoadFrameProbe {
    public static let shared: LoadFrameProbe? =
        ProcessInfo.processInfo.environment["CMUX_MOBILE_LOAD_PROBE"] == "1" ? LoadFrameProbe() : nil

    public private(set) var text = "{}"

    @ObservationIgnored private var placeholders: Set<String> = []
    @ObservationIgnored private var placeholdersChanged = false
    @ObservationIgnored private var watched: [Watched] = []
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var placeholderFrames = 0
    @ObservationIgnored private var shiftFrames = 0
    @ObservationIgnored private var shiftedRows = 0
    @ObservationIgnored private var lastChangeEpochMs: Double = 0
    @ObservationIgnored private var lastMoved = ""
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var extra: () -> [String: Any] = { [:] }

    private struct Watched {
        weak var view: UIScrollView?
        let rows: () -> [(String, CGRect)]
        var role: ((String) -> String)?
        let tag: Int
        var last: [String: CGRect] = [:]
        var traced = ""
    }

    @ObservationIgnored private var nextTag = 0
    @ObservationIgnored private var trace: SendFrameTrace? =
        ProcessInfo.processInfo.environment["CMUX_MOBILE_SEND_TRACE"] == "1" ? SendFrameTrace() : nil

    private init() {
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// A placeholder (`id`, unique per view) is on screen or gone.
    public func placeholder(_ id: String, shown: Bool) {
        let changed = shown ? placeholders.insert(id).inserted : placeholders.remove(id) != nil
        if changed { placeholdersChanged = true }
    }

    /// A list whose rows are compared frame to frame: `rows` gives each visible row's id and its
    /// frame in the list's visible bounds (content frame less the content offset).
    /// `role` names a row's part in a turn (`user`, `work`, `answer`, ...) for the send trace.
    public func watch(_ view: UIScrollView, rows: @escaping () -> [(String, CGRect)], role: ((String) -> String)? = nil) {
        nextTag += 1
        watched.append(Watched(view: view, rows: rows, role: role, tag: nextTag))
    }

    /// An app mark in the send trace (`send`: the composer's send ran).
    public func event(_ name: String) {
        trace?.write(String(format: "t=%.6f ev=%@", CACurrentMediaTime(), name))
    }

    /// More fields for the label (the row height memory's counters).
    public func report(_ fields: @escaping () -> [String: Any]) { extra = fields }

    fileprivate func tick() {
        frames += 1
        var changed = placeholdersChanged
        placeholdersChanged = false
        if !placeholders.isEmpty { placeholderFrames += 1 }
        var shifted = 0
        watched.removeAll { $0.view == nil }
        for index in watched.indices {
            guard let view = watched[index].view, view.window != nil else {
                if !watched[index].last.isEmpty { changed = true }
                watched[index].last = [:]
                if let trace, watched[index].role != nil, !watched[index].traced.isEmpty {
                    watched[index].traced = ""
                    trace.write(String(format: "t=%.6f v=%d off=0 rows=", CACurrentMediaTime(), watched[index].tag))
                }
                continue
            }
            let scrolling = view.isTracking || view.isDragging || view.isDecelerating
            var now: [String: CGRect] = [:]
            for (id, frame) in watched[index].rows() { now[id] = frame }
            let last = watched[index].last
            if now.count != last.count || now.keys.contains(where: { last[$0] == nil }) { changed = true }
            for (id, frame) in now {
                guard let before = last[id] else { continue }
                let moved = abs(before.minY - frame.minY) > 1 || abs(before.minX - frame.minX) > 1
                    || abs(before.height - frame.height) > 1 || abs(before.width - frame.width) > 1
                guard moved else { continue }
                changed = true
                if !scrolling {
                    shifted += 1
                    lastMoved = "\(id.prefix(32)) \(Int(before.minY))/\(Int(before.height))->\(Int(frame.minY))/\(Int(frame.height))"
                }
            }
            watched[index].last = now
            if let trace, let role = watched[index].role {
                let y = view.contentOffset.y
                let line = now.sorted { $0.value.minY < $1.value.minY }.map { id, frame in
                    let clean = id.prefix(48).map { "|; ".contains($0) ? "_" : $0 }
                    return "\(String(clean))|\(role(id))|\(Int((frame.minY + y).rounded()))|\(Int(frame.height.rounded()))"
                }.joined(separator: ";")
                if line != watched[index].traced {
                    watched[index].traced = line
                    trace.write(String(format: "t=%.6f v=%d off=%d rows=", CACurrentMediaTime(), watched[index].tag, Int(y.rounded())) + line)
                }
            }
        }
        if shifted > 0 {
            shiftFrames += 1
            shiftedRows += shifted
        }
        if changed { lastChangeEpochMs = Date().timeIntervalSince1970 * 1000 }
        if changed || shifted > 0 { publish() }
    }

    private func publish() {
        var json: [String: Any] = extra()
        json["frames"] = frames
        json["placeholderFrames"] = placeholderFrames
        json["shiftFrames"] = shiftFrames
        json["shiftedRows"] = shiftedRows
        json["lastChangeEpochMs"] = Int(lastChangeEpochMs)
        json["placeholders"] = placeholders.count
        json["lastMoved"] = lastMoved
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        let next = String(data: data, encoding: .utf8) ?? "{}"
        if next != text { text = next }
    }

    // Main-actor isolated, so the display link's callback (added to the main run loop) reaches
    // the probe without sending a task-isolated `self` into a main-actor closure.
    @MainActor
    private final class Ticker: NSObject {
        weak var probe: LoadFrameProbe?
        init(_ probe: LoadFrameProbe) { self.probe = probe }
        @objc func tick() { probe?.tick() }
    }
}

/// `Documents/send-trace.txt`, appended off the main thread (one line a frame at most).
private final class SendFrameTrace: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.send-trace", qos: .utility)
    private let handle: FileHandle?

    init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("send-trace.txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [handle] in try? handle?.write(contentsOf: data) }
    }
}

/// The probe's label (`debug.load-probe`), mounted once at the app's root.
public struct LoadFrameProbeLabel: View {
    public init() {}

    public var body: some View {
        if let probe = LoadFrameProbe.shared {
            Text(probe.text)
                .lineLimit(1)
                .frame(width: 4, height: 4)
                .clipped()
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityIdentifier("debug.load-probe")
                .accessibilityLabel(probe.text)
        }
    }
}

#endif

extension View {
    /// Counts this view's frames on screen as a loading placeholder's (`LoadFrameProbe`, DEBUG
    /// with `CMUX_MOBILE_LOAD_PROBE=1`); nothing otherwise.
    public func loadProbePlaceholder() -> some View {
        #if DEBUG
        modifier(LoadProbePlaceholder())
        #else
        self
        #endif
    }
}

#if DEBUG
private struct LoadProbePlaceholder: ViewModifier {
    @State private var id = UUID().uuidString

    func body(content: Content) -> some View {
        if let probe = LoadFrameProbe.shared {
            content
                .onAppear { probe.placeholder(id, shown: true) }
                .onDisappear { probe.placeholder(id, shown: false) }
        } else {
            content
        }
    }
}
#endif
#endif
