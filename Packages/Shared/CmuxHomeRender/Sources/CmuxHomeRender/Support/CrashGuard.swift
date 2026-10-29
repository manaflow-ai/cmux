import CmuxSafeConcurrency
import CoreGraphics
import Foundation
import os

/// Checked indexing and integer conversion for the render core. Layout state
/// can be stale (a row index from a previous model, a pixel size computed
/// from a NaN width), and an out-of-range subscript or an `Int(x)` that does
/// not fit traps the whole app. These accessors refuse or clamp instead and
/// report the call site's first fault of the launch as an
/// `Invariant.notFatalUntil` failure, so a wrong index
/// reaches crash reporting and the log without flooding either from a render
/// loop.
enum CrashGuard {
    static let log = Logger(subsystem: "com.cmuxterm.home.render", category: "crash-guard")
    /// The invariant name every CrashGuard fault reports under; each call site is its own site.
    static let invariantID: StaticString = "home-render-checked-access"
    /// The first build in which a CrashGuard fault traps instead of clamping. Not scheduled yet: set it to a
    /// real build once the reports of these sites stay at zero for a release cycle.
    static let fatalFromBuild = UInt64.max

    /// Reports `message` as the call site's first fault of the launch: to the
    /// process's invariant sink, and as a fault line in the log.
    static func fault(_ message: @autoclosure () -> String, fileID: StaticString = #fileID, line: UInt = #line) {
        guard Invariant.notFatalUntil(false, invariantID, build: fatalFromBuild, fileID: fileID, line: line) else {
            return
        }
        let site = "\(fileID):\(line)"
        let text = message()
        log.fault("\(site, privacy: .public): \(text, privacy: .public)")
    }

    /// `value` rounded toward zero as an Int, clamped to `range`; NaN gives
    /// `range.lowerBound`. A value outside `range` logs a fault once per site.
    static func int(_ value: Double, in range: ClosedRange<Int> = Int.min...Int.max,
                    fileID: StaticString = #fileID, line: UInt = #line) -> Int {
        guard value.isFinite else {
            fault("non-finite \(value), used \(value > 0 ? range.upperBound : range.lowerBound)", fileID: fileID, line: line)
            return value > 0 ? range.upperBound : range.lowerBound
        }
        if value >= Double(range.upperBound) {
            if value > Double(range.upperBound) { fault("\(value) above \(range.upperBound)", fileID: fileID, line: line) }
            return range.upperBound
        }
        if value <= Double(range.lowerBound) {
            if value < Double(range.lowerBound) { fault("\(value) below \(range.lowerBound)", fileID: fileID, line: line) }
            return range.lowerBound
        }
        return Int(exactly: value.rounded(.towardZero)) ?? range.lowerBound
    }

    static func int(_ value: CGFloat, in range: ClosedRange<Int> = Int.min...Int.max,
                    fileID: StaticString = #fileID, line: UInt = #line) -> Int {
        int(Double(value), in: range, fileID: fileID, line: line)
    }
}

extension Collection {
    /// The element at `index`, or nil when `index` is not a valid position.
    /// A miss logs a fault once per call site (a stale index is a bug, not a
    /// trap).
    subscript(checked index: Index, fileID: StaticString = #fileID, line: UInt = #line) -> Element? {
        guard index >= startIndex, index < endIndex else {
            CrashGuard.fault("index \(index) outside \(startIndex)..<\(endIndex)", fileID: fileID, line: line)
            return nil
        }
        return self[index] // crash-allow: startIndex <= index < endIndex checked above
    }

    /// `index` when it is a valid position, else nil with a fault logged once
    /// per call site. For writes: `if let i = rows.checkedIndex(i) { rows[i] = row }`.
    func checkedIndex(_ index: Index, fileID: StaticString = #fileID, line: UInt = #line) -> Index? {
        guard index >= startIndex, index < endIndex else {
            CrashGuard.fault("index \(index) outside \(startIndex)..<\(endIndex)", fileID: fileID, line: line)
            return nil
        }
        return index
    }
}

extension Collection {
    /// The elements in lower..<upper, clamped to the collection: a bound outside it or an
    /// inverted pair gives the part that exists (maybe empty), with a fault logged once per
    /// call site, instead of trapping on the range.
    func slice(_ lower: Index, _ upper: Index, fileID: StaticString = #fileID, line: UInt = #line) -> SubSequence {
        let lo = Swift.min(Swift.max(lower, startIndex), endIndex)
        let hi = Swift.min(Swift.max(upper, lo), endIndex)
        if lo != lower || hi != upper {
            CrashGuard.fault("slice \(lower)..<\(upper) outside \(startIndex)..<\(endIndex)", fileID: fileID, line: line)
        }
        return self[lo..<hi] // crash-allow: lo and hi clamped into startIndex...endIndex, lo <= hi
    }

    /// The elements from `lower` to the end (see `slice(_:_:)`).
    func slice(from lower: Index, fileID: StaticString = #fileID, line: UInt = #line) -> SubSequence {
        slice(lower, endIndex, fileID: fileID, line: line)
    }
}
