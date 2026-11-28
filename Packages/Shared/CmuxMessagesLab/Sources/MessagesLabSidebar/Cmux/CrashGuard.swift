import CoreGraphics
import Foundation
import os

// cmux (crash program, plans/cmux-next/crash-elimination.md): the same accessors as
// CmuxHomeRender's CrashGuard, for the vendored MessagesLab code (internal to this module).

/// Checked indexing and integer conversion for the render code. Layout state
/// can be stale (a row index from a previous model, a pixel size computed
/// from a NaN width), and an out-of-range subscript or an `Int(x)` that does
/// not fit traps the whole app. These accessors refuse or clamp instead, and
/// log a fault once per call site, so a wrong index stays visible in the log
/// without flooding it from a render loop.
enum CrashGuard {
    static let log = Logger(subsystem: "ai.manaflow.cmux", category: "messageslab-sidebar-crash-guard")
    private static let reported = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Logs `message` as a fault the first time `site` reports.
    static func fault(_ message: @autoclosure () -> String, fileID: StaticString = #fileID, line: UInt = #line) {
        let site = "\(fileID):\(line)"
        let first = reported.withLock { $0.insert(site).inserted }
        guard first else { return }
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

extension CrashGuard {
    /// Row and tile positions (RowList keeps rows as Int32): a clamped position stays far
    /// from Int overflow when the list adds a margin or a screen to it.
    static let rowRange: ClosedRange<Int> = -(1 << 31)...((1 << 31) - 1)
}
