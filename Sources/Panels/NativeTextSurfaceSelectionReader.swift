import AppKit
import Foundation

/// Maps an AppKit UTF-16 selection to source text and one-based line numbers.
@MainActor
final class NativeTextSurfaceSelectionReader {
    private typealias LineIndex = (starts: [Int], isComplete: Bool)

    private nonisolated static let maximumIndexedSourceUTF16Length = 16 * 1024 * 1024
    private nonisolated static let maximumIndexedLineStarts = 250_000

    private weak var observedTextStorage: NSTextStorage?
    private var editingObserver: NSObjectProtocol?
    private var cachedSource: String?
    private var cachedSourceUTF16Length: Int?
    private var cachedLineIndex: LineIndex?
    private var lineIndexTask: Task<LineIndex?, Never>?
    private var cacheGeneration = 0

    deinit {
        if let editingObserver {
            NotificationCenter.default.removeObserver(editingObserver)
        }
    }

    /// Stops observation and cancels any pending index construction.
    func close() {
        if let editingObserver {
            NotificationCenter.default.removeObserver(editingObserver)
            self.editingObserver = nil
        }
        lineIndexTask?.cancel()
        lineIndexTask = nil
        observedTextStorage = nil
        invalidateCache()
    }

    /// Reads the current selection without copying or scanning the document on every poll.
    func read(
        textView: NSTextView?,
        kind: PanelType,
        filePath: String
    ) async -> SurfaceSelectionSnapshot {
        let normalizedPath = URL(fileURLWithPath: filePath).standardizedFileURL.path
        guard let textView, let textStorage = textView.textStorage else {
            return .none(kind: kind, filePath: normalizedPath)
        }

        observe(textStorage)
        for _ in 0..<3 {
            let selectedRange = textView.selectedRange()
            let sourceLength = textStorage.length
            guard selectedRange.location != NSNotFound,
                  selectedRange.length > 0,
                  selectedRange.location <= sourceLength,
                  selectedRange.length <= sourceLength - selectedRange.location else {
                return .none(kind: kind, filePath: normalizedPath)
            }

            let generation = cacheGeneration
            let source: String
            if let cachedSource, cachedSourceUTF16Length == sourceLength {
                source = cachedSource
            } else if sourceLength <= Self.maximumIndexedSourceUTF16Length {
                let loadedSource = textStorage.string
                source = loadedSource
                cachedSource = loadedSource
                cachedSourceUTF16Length = sourceLength
            } else {
                return Self.snapshotFromStorage(
                    textStorage: textStorage,
                    selectedRange: selectedRange,
                    kind: kind,
                    filePath: normalizedPath
                )
            }

            let lineIndex = await lineIndex(for: source, generation: generation)
            guard !Task.isCancelled else {
                return .none(kind: kind, filePath: normalizedPath)
            }
            guard generation == cacheGeneration else { continue }
            return await Self.makeSnapshot(
                source: source,
                selectedLocation: selectedRange.location,
                selectedLength: selectedRange.length,
                lineIndex: lineIndex,
                kind: kind,
                filePath: normalizedPath
            )
        }

        guard !Task.isCancelled else {
            return .none(kind: kind, filePath: normalizedPath)
        }
        let selectedRange = textView.selectedRange()
        let sourceLength = textStorage.length
        guard selectedRange.location != NSNotFound,
              selectedRange.length > 0,
              selectedRange.location <= sourceLength,
              selectedRange.length <= sourceLength - selectedRange.location else {
            return .none(kind: kind, filePath: normalizedPath)
        }
        return Self.snapshotFromStorage(
            textStorage: textStorage,
            selectedRange: selectedRange,
            kind: kind,
            filePath: normalizedPath
        )
    }

    private func observe(_ textStorage: NSTextStorage) {
        guard observedTextStorage !== textStorage else { return }
        if let editingObserver {
            NotificationCenter.default.removeObserver(editingObserver)
            self.editingObserver = nil
        }
        invalidateCache()
        observedTextStorage = textStorage
        editingObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.willProcessEditingNotification,
            object: textStorage,
            queue: nil
        ) { [weak self] _ in
            // Text views in cmux are MainActor-owned; invalidating from the
            // synchronous will-process notification closes the same-length
            // edit window before the storage contents change.
            MainActor.assumeIsolated {
                self?.invalidateCache()
            }
        }
    }

    private func invalidateCache() {
        cacheGeneration &+= 1
        cachedSource = nil
        cachedSourceUTF16Length = nil
        cachedLineIndex = nil
        lineIndexTask?.cancel()
        lineIndexTask = nil
    }

    private func lineIndex(for source: String, generation: Int) async -> LineIndex? {
        if let cachedLineIndex {
            return cachedLineIndex
        }
        if let lineIndexTask {
            // This task is shared by concurrent reads for the same text
            // storage. Cache invalidation and close own its cancellation;
            // one canceled request must not discard work another request needs.
            let result = await Self.awaitSharedLineIndex(lineIndexTask)
            if generation == cacheGeneration, let result {
                cachedLineIndex = result
            }
            return result
        }

        let task = Task {
            await Self.buildLineIndex(source)
        }
        lineIndexTask = task
        let result = await Self.awaitSharedLineIndex(task)
        guard generation == cacheGeneration else { return nil }
        cachedLineIndex = result
        return result
    }

    private nonisolated static func awaitSharedLineIndex(
        _ task: Task<LineIndex?, Never>
    ) async -> LineIndex? {
        let (stream, continuation) = AsyncStream<LineIndex?>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let producer = Task {
            continuation.yield(await task.value)
            continuation.finish()
        }
        defer {
            producer.cancel()
            continuation.finish()
        }
        return await withTaskCancellationHandler(operation: {
            var iterator = stream.makeAsyncIterator()
            return (await iterator.next()) ?? nil
        }, onCancel: {
            // Finish this waiter without canceling the shared index task.
            producer.cancel()
            continuation.finish()
        })
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private nonisolated static func buildLineIndex(_ source: String) async -> LineIndex? {
        var starts = [0]
        starts.reserveCapacity(min(maximumIndexedLineStarts, 16_384))
        var offset = 0
        var previousWasCarriageReturn = false
        for unit in source.utf16 {
            if Task.isCancelled { return nil }
            switch unit {
            case 0x0D: // CR; CRLF is corrected when the following LF arrives.
                guard starts.count < maximumIndexedLineStarts else {
                    return (starts: starts, isComplete: false)
                }
                starts.append(offset + 1)
                previousWasCarriageReturn = true
            case 0x0A: // LF, including the second half of CRLF.
                if previousWasCarriageReturn {
                    starts[starts.count - 1] = offset + 1
                } else {
                    guard starts.count < maximumIndexedLineStarts else {
                        return (starts: starts, isComplete: false)
                    }
                    starts.append(offset + 1)
                }
                previousWasCarriageReturn = false
            case 0x85, 0x2028, 0x2029: // NEL, line separator, paragraph separator.
                guard starts.count < maximumIndexedLineStarts else {
                    return (starts: starts, isComplete: false)
                }
                starts.append(offset + 1)
                previousWasCarriageReturn = false
            default:
                previousWasCarriageReturn = false
            }
            offset += 1
            if offset & 0x0FFF == 0, Task.isCancelled { return nil }
        }
        return (starts: starts, isComplete: true)
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
        lineIndex: LineIndex?,
        kind: PanelType,
        filePath: String
    ) async -> SurfaceSelectionSnapshot {
        guard !Task.isCancelled else {
            return .none(kind: kind, filePath: filePath)
        }
        let boundedLength = min(selectedLength, SurfaceSelectionSnapshot.maximumTextBytes)
        let selectedText = substring(
            source,
            location: selectedLocation,
            length: boundedLength
        )
        let lineRange = lineIndex.flatMap { index -> SurfaceSelectionLineRange? in
            guard index.isComplete,
                  let start = lineNumber(atUTF16Offset: selectedLocation, in: index),
                  let end = lineNumber(
                      atUTF16Offset: selectedLocation + selectedLength - 1,
                      in: index
                  ) else {
                return nil
            }
            return SurfaceSelectionLineRange(start: start, end: end)
        }
        guard !Task.isCancelled else {
            return .none(kind: kind, filePath: filePath)
        }
        return .selected(
            kind: kind,
            text: SurfaceSelectionSnapshot.boundedText(selectedText),
            filePath: filePath,
            lineRange: lineRange
        )
    }

    private static func snapshotFromStorage(
        textStorage: NSTextStorage,
        selectedRange: NSRange,
        kind: PanelType,
        filePath: String
    ) -> SurfaceSelectionSnapshot {
        let boundedRange = NSRange(
            location: selectedRange.location,
            length: min(selectedRange.length, SurfaceSelectionSnapshot.maximumTextBytes)
        )
        let selectedText = textStorage.attributedSubstring(from: boundedRange).string
        return .selected(
            kind: kind,
            text: SurfaceSelectionSnapshot.boundedText(selectedText),
            filePath: filePath
        )
    }

    private nonisolated static func substring(_ source: String, location: Int, length: Int) -> String {
        let utf16 = source.utf16
        let start = String.Index(utf16Offset: location, in: source)
        let end = String.Index(utf16Offset: location + length, in: source)
        return String(decoding: utf16[start..<end], as: UTF16.self)
    }

    private nonisolated static func lineNumber(atUTF16Offset offset: Int, in index: LineIndex) -> Int? {
        guard index.isComplete else { return nil }
        var low = 0
        var high = index.starts.count
        while low < high {
            let middle = (low + high) / 2
            if index.starts[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(1, low)
    }
}
