public import Foundation
public import CmuxNextDesignTokens

/// The Motion Inspector as `JSONSerialization` object graphs: the `debug.motion` inspector actions and
/// `scripts/cmux-next/motion.py` read these. Milliseconds are rounded to 0.01.
extension MotionInspector {
    /// The `debug.motion` inspector actions (``MotionDebug``): `inspect_start`, `inspect_stop`, `time_scale`
    /// (`value`: 1, 2, 5, 10 or 0 for paused), `filter` (`categories`: names to keep, or null for all), `step`
    /// (`frames`: +1 forward, -1 back, any count), `running` (`ended`: true adds the ended ones), `findings`
    /// (scans the layer trees) and `inspector` (state and overhead). Returns nil for any other action.
    public func handle(_ action: String, _ params: [String: Any]) -> [String: Any]? {
        var extra: [String: Any] = [:]
        switch action {
        case "inspect_start":
            start()
        case "inspect_stop":
            stop()
            return report(records: true, endedRecords: true)
        case "time_scale":
            let value = (params["value"] as? NSNumber)?.doubleValue ?? (params["value"] as? String).flatMap(Double.init)
            guard let value, let scale = MotionTimeScale(value: value) else {
                return ["error": "time_scale value must be 1, 2, 5, 10 or 0 (paused)"]
            }
            setTimeScale(scale)
        case "filter":
            if let name = params["kind"] as? String {
                guard let kind = FilterKind(rawValue: name) else {
                    return ["error": "unknown kind; kinds: " + FilterKind.allCases.map(\.rawValue).joined(separator: ", ")]
                }
                setFilter(kind: kind)
            } else if let names = params["categories"] as? [String] {
                let kept = names.compactMap(MotionCategory.init(rawValue:))
                guard kept.count == names.count else {
                    return ["error": "unknown category; categories: " + MotionCategory.allCases.map(\.rawValue).joined(separator: ", ")]
                }
                setFilter(keeping: Set(kept))
            } else {
                setFilter(keeping: nil)
            }
        case "step":
            let frames = (params["frames"] as? NSNumber)?.intValue ?? 1  // clamped to ±maximumStep
            let moved = step(frames: frames)
            extra["step"] = ["seconds": Self.ms(moved.seconds * 1000) / 1000, "layers": moved.layers, "clock_frames": moved.clockFrames]
        case "running":
            return report(records: true, endedRecords: params["ended"] as? Bool ?? false)
        case "findings":
            scan()
            var out = report(records: false, endedRecords: false)
            out["findings"] = findings.map(Self.json)
            out["static_findings"] = Self.staticFindings.map { ["site": $0.site, "note": $0.note] }
            return out
        case "intents":
            // The one-intent check: every action seen and each one that started more than one top-level animation.
            return report(records: false, endedRecords: false).merging(intentsReport()) { _, new in new }
        case "inspector":
            break
        default:
            return nil
        }
        return report(records: false, endedRecords: false).merging(extra) { _, new in new }
    }

    /// State, overhead and (when asked) the records.
    public func report(records includeRecords: Bool, endedRecords: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "inspecting": isInspecting,
            "time_scale": timeScale.value,
            "paused": timeScale == .paused,
            "categories": (keptCategories.map { Array($0) } ?? MotionCategory.allCases).map(\.rawValue).sorted(),
            "filtered": keptCategories != nil,
            "kind": filterKind.map { $0.rawValue as Any } ?? NSNull(),
            "kinds": FilterKind.allCases.map(\.rawValue),
            "motion_ms": Self.ms(motionNow * 1000),
            "frame_ms": Self.ms(frameInterval * 1000),
            "running": records.filter(\.isRunning).count,
            "overhead": [
                "frame_p50_ms": Self.ms(overhead.framePercentile(0.5)), "frame_p95_ms": Self.ms(overhead.framePercentile(0.95)),
                "frame_max_ms": Self.ms(overhead.framePercentile(1)), "frames": overhead.frameMs.count,
                "starts": overhead.notes, "start_mean_ms": Self.ms(overhead.noteMeanMs), "start_max_ms": Self.ms(overhead.noteMaxMs),
                "scan_ms": overhead.lastScanMs.map { Self.ms($0) as Any } ?? NSNull(), "scanned_layers": overhead.scannedLayers,
            ] as [String: Any],
        ]
        if includeRecords {
            out["records"] = shownRecords.filter { endedRecords || $0.isRunning }.map(Self.json)
        }
        return out
    }

    static func json(_ record: MotionInspectorRecord) -> [String: Any] {
        var out: [String: Any] = [
            "id": record.id, "owner": record.owner, "kind": record.kind, "property": record.property, "runs": record.runs.rawValue,
            "layers": record.layers,
            "gated": record.gated, "start_ms": ms(record.start * 1000), "frames": record.frames, "dropped_frames": record.droppedFrames,
            "running": record.isRunning,
        ]
        if let site = record.site { out["site"] = site }
        if let intent = record.intent { out["intent"] = intent }
        if let type = record.ownerType { out["owner_type"] = type }
        if let category = record.category { out["category"] = category.rawValue }
        if let from = record.from { out["from"] = from }
        if let to = record.to { out["to"] = to }
        if let end = record.expectedEnd { out["expected_end_ms"] = ms(end * 1000) }
        if let end = record.ended { out["ended_ms"] = ms(end * 1000) }
        if let mean = record.mainMeanMs {
            out["main_ms_per_frame"] = ms(mean)
            out["main_max_ms"] = ms(record.mainMaxMs)
        }
        switch record.curve {
        case .spring(let response, let damping, let perceived):
            out["curve"] = ["type": "spring", "response": ms(response * 1000) / 1000, "damping": ms(damping),
                            "perceived_ms": ms(perceived * 1000)]
        case .timed(let seconds, let name):
            out["curve"] = ["type": "timed", "name": name, "duration_ms": ms(seconds * 1000)]
        case .loop(let period):
            out["curve"] = ["type": "loop", "period_ms": ms(period * 1000)]
        case .stepped:
            out["curve"] = ["type": "stepped"]
        }
        return out
    }

    static func json(_ finding: MotionInspectorFinding) -> [String: Any] {
        ["owner_type": finding.ownerType, "key": finding.key, "property": finding.property, "class": finding.animationClass,
         "duration_ms": ms(finding.seconds * 1000), "repeats": finding.repeats, "appkit_owned": finding.appKitOwned]
    }

    nonisolated static func ms(_ value: Double) -> Double {
        value.isFinite ? (value * 100).rounded() / 100 : 0
    }
}
