import AppKit
import Foundation

/// Maps an AppKit UTF-16 selection to source text and one-based line numbers.
nonisolated struct NativeTextSurfaceSelectionReader {
    @MainActor
    func read(
        textView: NSTextView?,
        kind: PanelType,
        filePath: String
    ) async -> SurfaceSelectionSnapshot {
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

        return await Self.makeSnapshot(
            source: source as String,
            selectedLocation: selectedRange.location,
            selectedLength: selectedRange.length,
            selectedText: source.substring(with: selectedRange),
            kind: kind,
            filePath: normalizedPath
        )
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private nonisolated static func makeSnapshot(
        source: String,
        selectedLocation: Int,
        selectedLength: Int,
        selectedText: String,
        kind: PanelType,
        filePath: String
    ) async -> SurfaceSelectionSnapshot {
        let source = source as NSString
        let startLine = lineNumber(atUTF16Offset: selectedLocation, in: source)
        let endLine = lineNumber(
            atUTF16Offset: selectedLocation + selectedLength - 1,
            in: source
        )
        return .selected(
            kind: kind,
            text: selectedText,
            filePath: filePath,
            lineRange: SurfaceSelectionLineRange(start: startLine, end: endLine)
        )
    }

    private nonisolated static func lineNumber(atUTF16Offset offset: Int, in source: NSString) -> Int {
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
