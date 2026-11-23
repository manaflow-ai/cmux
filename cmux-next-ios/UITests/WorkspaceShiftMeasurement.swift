import Foundation
import QuartzCore
import XCTest

/// Reads the DEBUG display-link trace used by WorkspaceEnterExitShiftUITests.
///
/// The application owns sampling. This type only defines the test contract and
/// the comparison, so it cannot change a transition while measuring it. A
/// frame is shifted when one of the edges of a visible landmark moves by at
/// least one point after that landmark's first frame in the transition.
@MainActor
final class WorkspaceShiftMeasurement {
    private struct Frame: Decodable {
        let t: Double
        let nominal: Double?
        let scale: Double?
        let boxes: [String: [Double]]
        let safeBottom: Double?
        let keyboardTop: Double?
        let pageOffsetX: [String: Double]?
        let tabBarTop: Double?
    }

    private struct Result: Encodable {
        let surface: String
        let direction: String
        let keyboardUp: Bool
        let workspaceID: String
        let frames: Int
        let shiftedFrames: Int
        let shiftedElements: [String: Int]
        let maximumDeltaPoints: [String: Double]
        let peakSignedDeltaPoints: [String: [Double]]
        let landmarks: [String]
        let missingLandmarks: [String]
        let malformedLines: Int
        let partialLine: Bool
        let firstShift: String?
    }

    private enum MeasurementError: LocalizedError {
        case probeMissing
        case tracePathMissing
        case traceUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .probeMissing: return "workspace shift recorder probe did not appear"
            case .tracePathMissing: return "workspace shift recorder did not publish a file path"
            case let .traceUnreadable(path): return "workspace shift trace is not readable: \(path)"
            }
        }
    }

    private struct Snapshot {
        let frames: [Frame]
        let completeLines: [String]
        let completeLineCount: Int
        let validFrameCount: Int
        let malformedLines: Int
        let partialLine: Bool
    }

    private let traceURL: URL
    private var baselineFrameCount: Int
    private var baselineLineCount: Int

    /// The probe's value is an absolute path in the simulator app container.
    /// The app creates the file before the test gets here.
    init(app: XCUIApplication) throws {
        let probe = app.staticTexts["debug.workspace-shift"].firstMatch
        guard probe.waitForExistence(timeout: 20) else { throw MeasurementError.probeMissing }
        let raw = (probe.value as? String) ?? probe.label
        guard let path = Self.path(from: raw), !path.isEmpty else { throw MeasurementError.tracePathMissing }
        traceURL = URL(fileURLWithPath: path)
        let initial = try Self.readSnapshot(at: traceURL)
        baselineFrameCount = initial.validFrameCount
        baselineLineCount = initial.completeLineCount
    }

    /// Runs one transition, then analyzes only display frames written after
    /// the action began. The short run-loop wait keeps the display link alive
    /// through the destination's settled frame without blocking it.
    func measure(
        in test: XCTestCase,
        surface: String,
        direction: String,
        keyboardUp: Bool,
        workspaceID: String,
        action: () throws -> Void,
        arrived: () throws -> Void
    ) throws {
        let baseline = try Self.readSnapshot(at: traceURL)
        baselineFrameCount = baseline.validFrameCount
        baselineLineCount = baseline.completeLineCount

        try action()
        try arrived()
        Self.runLoop(for: 0.45)

        let snapshot = try Self.readSnapshot(at: traceURL)
        let rawStart = baselineLineCount
        let start = min(baselineFrameCount, snapshot.frames.count)
        let frames = Array(snapshot.frames.dropFirst(start))
        let result = Self.analyze(frames, surface: surface, direction: direction,
                                  keyboardUp: keyboardUp, workspaceID: workspaceID,
                                  malformedLines: snapshot.malformedLines,
                                  partialLine: snapshot.partialLine)
        baselineFrameCount = snapshot.validFrameCount
        baselineLineCount = snapshot.completeLineCount

        let key = "\(surface).\(direction).keyboard-\(keyboardUp ? "up" : "down")"
        let summary = Self.summary(result, key: key)
        let raw = Self.rawLines(snapshot: snapshot, from: rawStart)
        Self.attach(summary, named: "workspace-shift-\(key)-summary", to: test)
        Self.attach(Self.json(result), named: "workspace-shift-\(key)-result.json", to: test)
        Self.attach(raw, named: "workspace-shift-\(key)-frames", to: test)
        Self.writeFastCheck(result, key: key)

        XCTAssertGreaterThan(result.frames, 0,
                             "\(key): recorder produced no complete display frames")
        XCTAssertTrue(result.missingLandmarks.isEmpty,
                      "\(key): missing stable landmarks \(result.missingLandmarks.joined(separator: ", ")); \(summary)")
        XCTAssertEqual(result.shiftedFrames, 0,
                       "\(key): shifted frames = \(result.shiftedFrames); \(summary)")
    }

    // MARK: Trace parsing and comparison

    private static let trackedPrefixes = [
        "page.", "content.", "toolbar.", "chat.composer.field", "terminal.composer.field",
        "accessory.", "list.bar",
    ]

    private static func analyze(
        _ frames: [Frame],
        surface: String,
        direction: String,
        keyboardUp: Bool,
        workspaceID: String,
        malformedLines: Int,
        partialLine: Bool
    ) -> Result {
        let expected = expectedLandmarks(surface: surface, direction: direction, keyboardUp: keyboardUp)
        var previous: [String: [Double]] = [:]
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        var shifted = Set<String>()
        var shiftedElementCounts: [String: Int] = [:]
        var maximum: [String: Double] = [:]
        var peakSigned: [String: [Double]] = [:]
        var firstShift: String?

        for (index, frame) in frames.enumerated() {
            var movedThisFrame = false
            var next: [String: [Double]] = [:]
            for (name, box) in frame.boxes where trackedPrefixes.contains(where: { name.hasPrefix($0) }) {
                guard box.count >= 4, box.prefix(4).allSatisfy({ $0.isFinite }) else { continue }
                seen.insert(name)
                counts[name, default: 0] += 1
                next[name] = Array(box.prefix(4))
                guard let old = previous[name], old.count >= 4 else { continue }
                let delta = zip(old.prefix(4), box.prefix(4)).map { pair in abs(pair.0 - pair.1) }.max() ?? 0
                maximum[name] = max(maximum[name] ?? 0, delta)
                let signed = zip(old.prefix(4), box.prefix(4)).map { pair in pair.1 - pair.0 }
                if let currentPeak = peakSigned[name], currentPeak.count == 4 {
                    peakSigned[name] = zip(currentPeak, signed).map { pair in
                        abs(pair.1) > abs(pair.0) ? pair.1 : pair.0
                    }
                } else {
                    peakSigned[name] = signed
                }
                if delta >= 1 {
                    movedThisFrame = true
                    shifted.insert(name)
                    shiftedElementCounts[name, default: 0] += 1
                    if firstShift == nil {
                        firstShift = String(format: "frame=%d t=%.4f element=%@ delta=%.1fpt", index, frame.t, name, delta)
                    }
                }
            }
            // An element hidden for a frame gets a new first frame when it
            // returns. A disappearance itself is not a geometric shift.
            previous = next
            if movedThisFrame { shifted.insert("__frame__") }
        }

        let landmarks = counts.filter { $0.value >= 2 }.map(\.key).sorted()
        let missing = expected.filter { requirement in
            if requirement == "toolbar.*" { return !counts.contains { $0.key.hasPrefix("toolbar.") && $0.value >= 2 } }
            if requirement == "agent composer or accessory" {
                return (counts["chat.composer.field"] ?? 0) < 2 && (counts["accessory.agent"] ?? 0) < 2
            }
            if requirement == "terminal composer or accessory" {
                return (counts["terminal.composer.field"] ?? 0) < 2 && (counts["accessory.terminal"] ?? 0) < 2
            }
            if requirement.hasPrefix("content.") {
                let surface = String(requirement.dropFirst("content.".count))
                return (counts["content.\(surface)"] ?? 0) < 2 && (counts["page.\(surface)"] ?? 0) < 2
            }
            return (counts[requirement] ?? 0) < 2
        }
        let shiftedFrames = shifted.contains("__frame__")
            ? frames.indices.reduce(into: 0) { count, index in
                let frame = frames[index]
                let current = frame.boxes.filter { entry in
                    trackedPrefixes.contains { prefix in entry.key.hasPrefix(prefix) }
                }
                let before = index > 0 ? frames[index - 1].boxes : [:]
                if current.contains(where: { name, box in
                    guard let old = before[name], box.count >= 4, old.count >= 4 else { return false }
                    return zip(old.prefix(4), box.prefix(4)).contains { pair in abs(pair.0 - pair.1) >= 1 }
                }) { count += 1 }
            }
            : 0

        return Result(surface: surface, direction: direction, keyboardUp: keyboardUp,
                      workspaceID: workspaceID, frames: frames.count, shiftedFrames: shiftedFrames,
                      shiftedElements: shiftedElementCounts, maximumDeltaPoints: maximum,
                      peakSignedDeltaPoints: peakSigned,
                      landmarks: landmarks, missingLandmarks: missing, malformedLines: malformedLines,
                      partialLine: partialLine, firstShift: firstShift)
    }

    private static func expectedLandmarks(surface: String, direction: String, keyboardUp: Bool) -> [String] {
        var expected = ["content.\(surface)"]
        // Toolbar controls can be obscured while the browser exits with its
        // address field editing. Any one control is enough for that case.
        expected.append("toolbar.*")
        if surface == "agent" { expected.append("agent composer or accessory") }
        if surface == "terminal" { expected.append("terminal composer or accessory") }
        return expected
    }

    private static func path(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) }
        if let marker = trimmed.range(of: "file=") {
            let rest = String(trimmed[marker.upperBound...])
            return rest.split(separator: " ", maxSplits: 1).first.map { String($0).replacingOccurrences(of: "%20", with: " ") }
        }
        return nil
    }

    private static func readSnapshot(at url: URL) throws -> Snapshot {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw MeasurementError.traceUnreadable(url.path)
        }
        let hasPartial = !text.isEmpty && !text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let complete = hasPartial ? lines.dropLast() : lines[...]
        let decoder = JSONDecoder()
        var frames: [Frame] = []
        var malformed = 0
        for line in complete where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let frame = try? decoder.decode(Frame.self, from: Data(line.utf8)) else { malformed += 1; continue }
            frames.append(frame)
        }
        return Snapshot(frames: frames, completeLines: complete.map { String($0) }, completeLineCount: complete.count, validFrameCount: frames.count,
                        malformedLines: malformed, partialLine: hasPartial)
    }

    private static func rawLines(snapshot: Snapshot, from index: Int) -> String {
        let start = min(index, snapshot.completeLines.count)
        return snapshot.completeLines.dropFirst(start).joined(separator: "\n")
    }

    private static func runLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func summary(_ result: Result, key: String) -> String {
        let moved = result.shiftedElements.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let maxes = result.maximumDeltaPoints.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.1f", $0.value))pt" }.joined(separator: ",")
        let signed = result.peakSignedDeltaPoints.sorted { $0.key < $1.key }.map { entry in
            let values = entry.value.map { String(format: "%.1f", $0) }.joined(separator: ",")
            return "\(entry.key)=[\(values)]"
        }.joined(separator: ",")
        return "case=\(key) frames=\(result.frames) shiftedFrames=\(result.shiftedFrames) shiftedElements=[\(moved)] maxDelta=[\(maxes)] signedDelta=[\(signed)] landmarks=\(result.landmarks.joined(separator: ",")) missing=\(result.missingLandmarks.joined(separator: ",")) malformed=\(result.malformedLines) partial=\(result.partialLine) first=\(result.firstShift ?? "-")"
    }

    private static func attach(_ text: String, named name: String, to test: XCTestCase) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    private static func json(_ result: Result) -> String {
        guard let data = try? JSONEncoder().encode(result), let text = String(data: data, encoding: .utf8) else {
            return "{}\n"
        }
        return text + "\n"
    }

    private static func writeFastCheck(_ result: Result, key: String) {
        guard let output = ProcessInfo.processInfo.environment["FAST_CHECKS_OUT"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("workspace-shift.jsonl")
        guard let data = try? JSONEncoder().encode(result) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(data); handle.write(Data("\n".utf8)); try? handle.close()
        } else {
            var payload = data
            payload.append(Data("\n".utf8))
            try? payload.write(to: file)
        }
        _ = key
    }
}
