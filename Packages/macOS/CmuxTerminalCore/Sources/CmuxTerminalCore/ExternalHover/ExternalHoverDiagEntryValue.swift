import Foundation

/// (C) ExternalHover diagnostics — Swift mirror of Ghostty's
/// `ghostty_external_hover_diag_entry_s` / Zig's `ExternalHoverDiagEntry`.
/// Pure and POD-shaped (no strings, no pointers) — decoding raw enum
/// bytes into log-friendly strings is a separate step
/// (`ExternalHoverDiag*.describe`), kept out of this type so constructing
/// one never allocates.
public struct ExternalHoverDiagEntryValue: Sendable, Equatable {
    public let event: UInt64
    public let source: UInt8
    public let reason: UInt8
    public let verdict: UInt8
    public let flags: UInt8
    public let seq: UInt32

    public init(event: UInt64, source: UInt8, reason: UInt8, verdict: UInt8, flags: UInt8, seq: UInt32) {
        self.event = event
        self.source = source
        self.reason = reason
        self.verdict = verdict
        self.flags = flags
        self.seq = seq
    }

    /// `flags` bit 0 (design-hover-diagnostics-v4-final.md §3.2).
    public var firstForActivation: Bool {
        flags & 0x1 != 0
    }

    /// `flags` bit 1 — diagnostics-only, added for the #8810 investigation
    /// into the ~426ms setter-to-transition delivery delay. Set only on
    /// the `source=render` entry `generic.zig`'s render loop pushes at
    /// the exact point it creates a transition value snapshot (never on
    /// the ordinary per-frame validation entry `recordRenderVerdict`
    /// pushes) — see `link.zig`'s `external_hover_diag_flag_transition_snapshot`
    /// doc.
    public var isTransitionSnapshot: Bool {
        flags & 0x2 != 0
    }
}

/// `source` field decode. Every entry has exactly one source — there is no
/// `.none`/`unknown` case in the design's own enum table, but an
/// out-of-date host decoding an entry from a newer Ghostty build could
/// still see an unrecognized raw value, so this fails safe to a labeled
/// string rather than crashing (design v4 §3.2: "未知の enum value は host
/// が crash せず `unknown(<raw>)` として出す").
public enum ExternalHoverDiagSourceValue: UInt8 {
    case setter = 1
    case input = 2
    case render = 3

    public static func describe(_ raw: UInt8) -> String {
        guard let value = ExternalHoverDiagSourceValue(rawValue: raw) else {
            return "unknown(\(raw))"
        }
        switch value {
        case .setter: return "setter"
        case .input: return "input"
        case .render: return "render"
        }
    }
}

/// `reason` field decode — populated for `source=setter`/`source=input`
/// entries; raw value 0 (`.none`) means "not applicable to this entry".
/// Raw values mirror `src/renderer/link.zig`'s `ExternalHoverDiagReason`
/// exactly; keep both in sync.
public enum ExternalHoverDiagReasonValue: UInt8 {
    case none = 0
    case zeroRowCount = 1
    case hoverIneligible = 2
    case scopeOutOfBounds = 3
    case snapshotBuildFailed = 4
    case pointerMissing = 5
    case pointerNotInRanges = 6
    case rangeCountExceeded = 7
    case rangeOutOfScope = 8
    case rangeEmptyOrInverted = 9
    case cellBudgetExceeded = 10
    case viewportExit = 11
    case renderQueueFailed = 12

    public static func describe(_ raw: UInt8) -> String {
        guard let value = ExternalHoverDiagReasonValue(rawValue: raw) else {
            return "unknown(\(raw))"
        }
        switch value {
        case .none: return "none"
        case .zeroRowCount: return "zeroRowCount"
        case .hoverIneligible: return "hoverIneligible"
        case .scopeOutOfBounds: return "scopeOutOfBounds"
        case .snapshotBuildFailed: return "snapshotBuildFailed"
        case .pointerMissing: return "pointerMissing"
        case .pointerNotInRanges: return "pointerNotInRanges"
        case .rangeCountExceeded: return "rangeCountExceeded"
        case .rangeOutOfScope: return "rangeOutOfScope"
        case .rangeEmptyOrInverted: return "rangeEmptyOrInverted"
        case .cellBudgetExceeded: return "cellBudgetExceeded"
        case .viewportExit: return "viewportExit"
        case .renderQueueFailed: return "renderQueueFailed"
        }
    }
}

/// `verdict` field decode — populated for `source=render` entries; raw
/// value 0 (`.none`) means "not applicable". Raw values mirror
/// `src/renderer/link.zig`'s `ExternalHoverDiagVerdict` exactly; keep both
/// in sync.
public enum ExternalHoverDiagVerdictValue: UInt8 {
    case none = 0
    case valid = 1
    case osc8Present = 2
    case hoverIneligible = 3
    case scopeOutOfBounds = 4
    case pointerMissing = 5
    case pointerNotInRanges = 6
    case viewportExit = 7
    case physicalTokenMismatch = 8
    case contextEpochMismatch = 9
    case snapshotBuildFailed = 10
    case renderQueueFailed = 11

    public static func describe(_ raw: UInt8) -> String {
        guard let value = ExternalHoverDiagVerdictValue(rawValue: raw) else {
            return "unknown(\(raw))"
        }
        switch value {
        case .none: return "none"
        case .valid: return "valid"
        case .osc8Present: return "osc8Present"
        case .hoverIneligible: return "hoverIneligible"
        case .scopeOutOfBounds: return "scopeOutOfBounds"
        case .pointerMissing: return "pointerMissing"
        case .pointerNotInRanges: return "pointerNotInRanges"
        case .viewportExit: return "viewportExit"
        case .physicalTokenMismatch: return "physicalTokenMismatch"
        case .contextEpochMismatch: return "contextEpochMismatch"
        case .snapshotBuildFailed: return "snapshotBuildFailed"
        case .renderQueueFailed: return "renderQueueFailed"
        }
    }
}

extension ExternalHoverDiagEntryValue {
    /// One `stage=ghosttyValidation` log line (design v4 §5), with
    /// `surfaceSerial` supplied by the caller (never carried by the entry
    /// itself — see the type's doc). Field order matches the project's
    /// established convention of non-sensitive-fields-first (there are no
    /// sensitive fields here at all: only enum reasons, counts, and
    /// booleans — no raw path/cwd/row text/URL/token, per design v4 §5's
    /// secrecy policy).
    public func describeLine(surfaceSerial: UInt64) -> String {
        let sourceText = ExternalHoverDiagSourceValue.describe(source)
        let reasonText = ExternalHoverDiagReasonValue.describe(reason)
        let verdictText = ExternalHoverDiagVerdictValue.describe(verdict)
        return "stage=ghosttyValidation surfaceSerial=\(surfaceSerial) event=\(event) " +
            "source=\(sourceText) reason=\(reasonText) verdict=\(verdictText) " +
            "firstForActivation=\(firstForActivation) transitionSnapshot=\(isTransitionSnapshot) seq=\(seq)"
    }
}
