import AppKit
import Foundation

/// Maps an AppKit UTF-16 selection to source text and one-based line numbers.
nonisolated struct NativeTextSurfaceSelectionReader {
    @MainActor
    func read(
        textView: NSTextView?,
        kind: PanelType,
        filePath: String
    ) -> SurfaceSelectionSnapshot {
        let normalizedPath = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard let textView else {
            return .none(kind: kind, filePath: normalizedPath)
        }

        let source = textView.string as NSString
        let selectedRange = textView.selectedRange()
        guard selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              selectedRange.location <= source.length,
              selectedRange.length <= source.length - selectedRange.location else {
            return .none(kind: kind, filePath: normalizedPath)
        }

        let startLine = lineNumber(atUTF16Offset: selectedRange.location, in: source)
        let lastSelectedOffset = NSMaxRange(selectedRange) - 1
        let endLine = lineNumber(atUTF16Offset: lastSelectedOffset, in: source)
        return .selected(
            kind: kind,
            text: source.substring(with: selectedRange),
            filePath: normalizedPath,
            lineRange: SurfaceSelectionLineRange(start: startLine, end: endLine)
        )
    }

    private func lineNumber(atUTF16Offset offset: Int, in source: NSString) -> Int {
        guard offset > 0 else { return 1 }

        var lineNumber = 1
        var cursor = 0
        while cursor < offset {
            var lineEnd = 0
            source.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: nil,
                for: NSRange(location: cursor, length: 0)
            )
            guard lineEnd > cursor, lineEnd <= offset else { break }
            lineNumber += 1
            cursor = lineEnd
        }
        return lineNumber
    }
}
