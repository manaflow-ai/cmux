import Foundation
import QuartzCore
import XCTest

/// The runner and app share the simulator's monotonic display clock. Keep the
/// last pre-action frame and every tick through arrival and settling.
@MainActor
final class WorkspaceShiftMeasurement {
    private struct Frame: Decodable {
        let t: Double
        let nominal: Double
        let boxes: [String: [Double]]
        let pageOffsetX: [String: Double]
    }

    private struct Shift: Encodable {
        let frame: Int
        let time: Double
        let deltaPoints: [String: [Double]]
    }

    private struct Result: Encodable {
        let surface: String
        let direction: String
        let keyboardUp: Bool
        let workspaceID: String
        let actionStart: Double
        let actionStartUnixSeconds: Double
        let captureEnd: Double
        let frames: Int
        var shiftedFrames = 0
        var shifts: [Shift] = []
        var comparablePairs: [String: Int] = [:]
        var peakSignedEdgeDeltas: [String: [Double]] = [:]
        var shiftedElementFrames: [String: Int] = [:]
        var movingPagePairs = 0
        var maxTickIntervalMS = 0.0
        var missedTicksDuringMotion = 0
        var coverageErrors: [String] = []
    }

    private let traceURL: URL

    init(app: XCUIApplication) throws {
        let probe = app.staticTexts["debug.workspace-shift"].firstMatch
        guard probe.waitForExistence(timeout: 20), let path = probe.value as? String,
              path.hasPrefix("/") else { throw failure("Missing workspace display-link trace path") }
        traceURL = URL(fileURLWithPath: path)
    }

    func measure(
        in test: XCTestCase, surface: String, direction: String, keyboardUp: Bool, workspaceID: String,
        action: () throws -> Void, arrived: () throws -> Void
    ) throws {
        let start = CACurrentMediaTime()
        let startWallTime = Date().timeIntervalSince1970
        try action()
        try arrived()
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        let end = CACurrentMediaTime()
        // Leave time for the off-main writer to commit the first tick past end.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let text = try String(contentsOf: traceURL, encoding: .utf8)
        // The file is live. A final unterminated line may still be writing.
        let lines = text.components(separatedBy: "\n").dropLast()
        let decoder = JSONDecoder()
        let all = try lines.map { try decoder.decode(Frame.self, from: Data($0.utf8)) }
        guard let first = all.lastIndex(where: { $0.t <= start }),
              let last = all.firstIndex(where: { $0.t >= end }), first < last else {
            throw failure("Incomplete trace across \(surface) \(direction) at \(start)...\(end)")
        }
        let frames = Array(all[first...last])
        var result = Result(surface: surface, direction: direction, keyboardUp: keyboardUp,
                            workspaceID: workspaceID, actionStart: start, actionStartUnixSeconds: startWallTime,
                            captureEnd: end, frames: frames.count)
        let page = "page.\(surface)"
        let row = "workspace.row.\(workspaceID)"
        let content = "content.\(surface)"
        // The last line ("end.") is recorded but not gated: a streaming terminal or a
        // growing page moves it by design.
        let lastLine = "end.\(surface)"
        let allowed = Set([page, row, content, "accessory.\(surface)",
                           surface == "agent" ? "chat.composer.field" : "\(surface).composer.field"])
        // A slow correction can move several points in sub-point increments.
        // Keep each visible edge's last accepted position as well as the prior
        // frame. Only count the tick crossing the threshold; a stationary
        // plateau after a jump does not add shifted frames.
        var anchors: [String: [Double]] = [:]
        for index in frames.indices.dropFirst() {
            let previous = frames[index - 1]
            let current = frames[index]
            let interval = current.t - previous.t
            result.maxTickIntervalMS = max(result.maxTickIntervalMS, interval * 1000)
            if [row, page].contains(where: { id in
                guard let before = previous.pageOffsetX[id], let after = current.pageOffsetX[id] else { return false }
                return abs(after - before) > 0.25
            }) {
                result.movingPagePairs += 1
                if previous.nominal > 0, interval > previous.nominal * 1.5 {
                    result.missedTicksDuringMotion += max(1, Int((interval / previous.nominal).rounded()) - 1)
                }
            }
            anchors = anchors.filter { current.boxes[$0.key] != nil }
            var moved: [String: [Double]] = [:]
            for (id, box) in current.boxes where allowed.contains(id) || id.hasPrefix("toolbar.") {
                guard let old = previous.boxes[id], old.count == 4, box.count == 4 else { continue }
                result.comparablePairs[id, default: 0] += 1
                // A content line (the first or the last) counts only where it could be seen,
                // before or after: off the viewport in both frames it moved nothing on screen.
                if id == content || id == lastLine {
                    let port = "viewport.\(surface)"
                    func seen(_ frame: Frame, _ line: Double) -> Bool {
                        guard let view = frame.boxes[port], view.count == 4 else { return true }
                        return line >= view[1] - 1 && line <= view[1] + view[3] + 1
                    }
                    if !seen(previous, old[1]) && !seen(current, box[1]) { continue }
                }
                // The page/content landmark represents its top edge. A change in
                // the height below that edge is not motion of that landmark.
                let before = edges(old, topOnly: id == page || id == content || id == lastLine)
                let after = edges(box, topOnly: id == page || id == content || id == lastLine)
                var anchor = anchors[id] ?? before
                let delta = after.indices.map { edge in
                    let step = after[edge] - before[edge]
                    let accumulated = after[edge] - anchor[edge]
                    let movement = abs(accumulated) >= abs(step) ? accumulated : step
                    if abs(movement) >= 1 { anchor[edge] = after[edge] }
                    return movement
                }
                anchors[id] = anchor
                guard delta.contains(where: { abs($0) >= 1 }) else { continue }
                moved[id] = delta
                result.shiftedElementFrames[id, default: 0] += 1
                let peaks = result.peakSignedEdgeDeltas[id] ?? Array(repeating: 0, count: delta.count)
                result.peakSignedEdgeDeltas[id] = zip(delta, peaks).map { abs($0.0) > abs($0.1) ? $0.0 : $0.1 }
            }
            if !moved.isEmpty {
                result.shifts.append(Shift(frame: index, time: current.t, deltaPoints: moved))
            }
        }
        for id in [row, page, content] where result.comparablePairs[id] == nil {
            result.coverageErrors.append("No consecutive visible samples for \(id)")
        }
        if !(keyboardUp && direction == "exit"), !result.comparablePairs.keys.contains(where: { $0.hasPrefix("toolbar.") }) {
            result.coverageErrors.append("No consecutive visible toolbar samples")
        }
        if !keyboardUp, surface != "browser", result.comparablePairs["accessory.\(surface)"] == nil,
           result.comparablePairs[surface == "agent" ? "chat.composer.field" : "terminal.composer.field"] == nil {
            result.coverageErrors.append("No consecutive composer or accessory samples")
        }
        if result.movingPagePairs < 2 { result.coverageErrors.append("Missing intermediate navigation frames") }
        // A missed tick is a hitch (frame time, reported below), not a blind spot: a jump
        // between two samples is still a delta between consecutive samples, so it is counted.

        let key = "\(surface).\(direction).keyboard-\(keyboardUp ? "up" : "down")"
        result.shiftedFrames = result.shifts.count
        let encoded = try JSONEncoder().encode(result)
        let summary = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        summary.name = "workspace-shift-\(key)-result.json"
        summary.lifetime = .keepAlways
        test.add(summary)
        let raw = XCTAttachment(string: lines[first...last].joined(separator: "\n"))
        raw.name = "workspace-shift-\(key)-frames.jsonl"
        raw.lifetime = .keepAlways
        test.add(raw)
        let hz: Double = frames.first.map { $0.nominal > 0 ? (1 / $0.nominal).rounded() : 0 } ?? 0
        var firstShifts: [String] = []
        for shift in result.shifts.prefix(4) {
            let ms = Int(((shift.time - start) * 1000).rounded())
            var parts: [String] = []
            for (key, value) in shift.deltaPoints.sorted(by: { $0.key < $1.key }) {
                let points: [Int] = value.map { Int($0.rounded()) }
                parts.append("\(key)=\(points)")
            }
            firstShifts.append("#\(shift.frame)@\(ms)ms " + parts.joined(separator: ","))
        }
        let message = "\(key) shiftedFrames=\(result.shiftedFrames) frames=\(result.frames) " +
            "hz=\(Int(hz)) maxFrameMS=\(String(format: "%.1f", result.maxTickIntervalMS)) " +
            "missedTicks=\(result.missedTicksDuringMotion) shifts=\(firstShifts) " +
            "peakSignedEdgeDeltas=\(result.peakSignedEdgeDeltas) coverage=\(result.coverageErrors)"
        print("WORKSPACE_SHIFT \(message)")
        XCTAssertTrue(result.coverageErrors.isEmpty, message)
        XCTAssertEqual(result.shiftedFrames, 0, message)
    }

    private func edges(_ box: [Double], topOnly: Bool) -> [Double] {
        let edges = [box[0], box[1], box[0] + box[2]]
        return topOnly ? edges : edges + [box[1] + box[3]]
    }
}

private func failure(_ message: String) -> NSError {
    NSError(domain: "WorkspaceShiftMeasurement", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
