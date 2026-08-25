import AppKit
import Foundation

extension SurfaceSelectionChangeEventPublisher {
    func registerTerminalSurface(_ panel: TerminalPanel) {
        let surfaceView = panel.hostedView.surfaceView
        let signal = surfaceView.selectionChangeSignal
        register(
            surfaceId: panel.id,
            sourceIdentity: ObjectIdentifier(signal),
            events: signal.events,
            identity: { [weak panel] in
                guard let panel else { return nil }
                return SurfaceSelectionEventIdentity.live(
                    workspaceId: panel.workspaceId,
                    surfaceId: panel.id
                )
            },
            reader: { [weak panel] in
                guard let panel,
                      let selection = panel.hostedView.surfaceView.readSelectionSnapshot() else {
                    return .none(kind: PanelType.terminal.rawValue)
                }
                return .selected(
                    kind: PanelType.terminal.rawValue,
                    text: selection.string
                )
            }
        )
    }

    func registerNativeTextSurface(
        surfaceId: UUID,
        workspaceId: @escaping @MainActor () -> UUID?,
        kind: String,
        filePath: String?,
        textView: NSTextView
    ) {
        registerNativeTextSource(
            surfaceId: surfaceId,
            textView: textView,
            identity: { [weak textView] in
                guard let workspaceId = workspaceId(), textView != nil else { return nil }
                return SurfaceSelectionEventIdentity.live(
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
            },
            reader: { [weak textView] in
                guard let textView else {
                    return nil
                }
                return Self.nativeSnapshot(
                    from: textView,
                    kind: kind,
                    filePath: filePath
                )
            }
        )
    }

    private static func nativeSnapshot(
        from textView: NSTextView,
        kind: String,
        filePath: String?
    ) -> SurfaceSelectionEventSnapshot {
        let normalizedFilePath = filePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let string = textView.string as NSString
        let selectedRange = textView.selectedRange()
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.location <= string.length else {
            return .none(kind: kind, filePath: normalizedFilePath)
        }
        let clampedLength = min(selectedRange.length, string.length - selectedRange.location)
        guard clampedLength > 0 else {
            return .none(kind: kind, filePath: normalizedFilePath)
        }
        let range = NSRange(location: selectedRange.location, length: clampedLength)
        let text = string.substring(with: range)
        let lastOffset = max(range.location, NSMaxRange(range) - 1)
        let lineRange = lineNumber(in: string, at: range.location)...lineNumber(in: string, at: lastOffset)
        return .selected(
            kind: kind,
            text: text,
            filePath: normalizedFilePath,
            lineRange: lineRange
        )
    }

    private static func lineNumber(in string: NSString, at utf16Offset: Int) -> Int {
        let offset = min(max(0, utf16Offset), string.length)
        let prefix = string.substring(with: NSRange(location: 0, length: offset))
        return prefix.utf8.reduce(into: 1) { line, byte in
            if byte == 0x0A { line += 1 }
        }
    }
}
