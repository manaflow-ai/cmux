import Foundation

/// The Unicode scalar that terminates one logical text line.
///
/// The storage keeps the kind alongside each break so an edit can split or
/// join a CRLF pair without retaining the complete document. Values are packed
/// into the existing offset slot, keeping dense newline-heavy documents at the
/// same per-entry footprint as a plain `[Int]` index.
enum FilePreviewLineBreakKind: Int, Sendable {
    case lineFeed
    case carriageReturn
    case carriageReturnLineFeed
    case lineSeparator
    case paragraphSeparator

    var length: Int {
        self == .carriageReturnLineFeed ? 2 : 1
    }

    /// Raw UTF-16 units represented by this logical break.
    var rawUnits: [UInt16] {
        switch self {
        case .lineFeed:
            [0x0A]
        case .carriageReturn:
            [0x0D]
        case .carriageReturnLineFeed:
            [0x0D, 0x0A]
        case .lineSeparator:
            [0x2028]
        case .paragraphSeparator:
            [0x2029]
        }
    }
}

struct FilePreviewLineBreakUnit: Sendable {
    var offset: Int
    var kind: FilePreviewLineBreakKind
}

extension FilePreviewLineIndexStorage {
    /// Enumerates logical line breaks, combining an adjacent CRLF pair.
    static func lineBreaks(
        in string: String,
        offset: Int = 0
    ) -> [FilePreviewLineBreakUnit] {
        var result: [FilePreviewLineBreakUnit] = []
        var position = offset
        var pendingCarriageReturn = false
        for unit in string.utf16 {
            if pendingCarriageReturn {
                if unit == 0x0A {
                    result.append(FilePreviewLineBreakUnit(
                        offset: position - 1,
                        kind: .carriageReturnLineFeed
                    ))
                    pendingCarriageReturn = false
                    position += 1
                    continue
                }
                result.append(FilePreviewLineBreakUnit(
                    offset: position - 1,
                    kind: .carriageReturn
                ))
                pendingCarriageReturn = false
            }

            switch unit {
            case 0x0D:
                pendingCarriageReturn = true
            case 0x0A:
                result.append(FilePreviewLineBreakUnit(offset: position, kind: .lineFeed))
            case 0x2028:
                result.append(FilePreviewLineBreakUnit(offset: position, kind: .lineSeparator))
            case 0x2029:
                result.append(FilePreviewLineBreakUnit(offset: position, kind: .paragraphSeparator))
            default:
                break
            }
            position += 1
        }
        if pendingCarriageReturn {
            result.append(FilePreviewLineBreakUnit(
                offset: position - 1,
                kind: .carriageReturn
            ))
        }
        return result
    }

    /// Merges a sequence already ordered by offset without sorting it.
    static func mergeAdjacentLineBreaks(
        _ units: [FilePreviewLineBreakUnit]
    ) -> [FilePreviewLineBreakUnit] {
        guard !units.isEmpty else { return [] }
        var result: [FilePreviewLineBreakUnit] = []
        result.reserveCapacity(units.count)
        for unit in units {
            if let previous = result.last,
               previous.kind == .carriageReturn,
               unit.kind == .lineFeed,
               unit.offset == previous.offset + 1 {
                result[result.count - 1].kind = .carriageReturnLineFeed
            } else if let previous = result.last,
                      previous.offset == unit.offset,
                      previous.kind == unit.kind {
                continue
            } else {
                result.append(unit)
            }
        }
        return result
    }
}
