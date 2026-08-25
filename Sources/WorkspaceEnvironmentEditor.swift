import AppKit
import Foundation

/// Presents and applies the user-editable environment attached to one workspace.
///
/// The environment is intentionally edited as KEY=VALUE lines. This keeps the
/// dialog compact while making add, replace, and remove operations obvious:
/// add a line, edit a line, or delete a line. Values are split on their first
/// equals sign so URLs and other values containing `=` round-trip unchanged.
@MainActor
final class WorkspaceEnvironmentEditor {
    enum ParseError: Equatable, Error {
        case invalidAssignment(line: Int)
        case emptyKey(line: Int)
        case emptyValue(line: Int)
        case invalidKey(line: Int)
        case invalidValue(line: Int)
        case duplicateKey(line: Int)

        var line: Int {
            switch self {
            case let .invalidAssignment(line),
                 let .emptyKey(line),
                 let .emptyValue(line),
                 let .invalidKey(line),
                 let .invalidValue(line),
                 let .duplicateKey(line):
                return line
            }
        }
    }

    private let workspace: Workspace
    private let textView: NSTextView

    init(workspace: Workspace) {
        self.workspace = workspace
        self.textView = Self.makeTextView(
            initialText: Self.serializedEnvironment(workspace.workspaceEnvironment)
        )
    }

    func present() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.workspaceEnvironment.title",
            defaultValue: "Workspace Environment"
        )
        alert.informativeText = String(
            localized: "dialog.workspaceEnvironment.message",
            defaultValue: "Enter one KEY=VALUE pair per line. Delete a line to remove a variable. Changes apply to new terminals; existing shells keep their current environment. CMUX_* values remain managed by cmux."
        )
        alert.addButton(withTitle: String(
            localized: "dialog.workspaceEnvironment.save",
            defaultValue: "Save"
        ))
        alert.addButton(withTitle: String(
            localized: "common.cancel",
            defaultValue: "Cancel"
        ))
        alert.accessoryView = Self.makeAccessoryView(for: textView)

        let presentingWindow = AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id)
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = textView
        var shouldPlaceCursorAtEnd = true

        while true {
            let placeCursorAtEnd = shouldPlaceCursorAtEnd
            shouldPlaceCursorAtEnd = false
            let response = alert.runCmuxModal(
                presentingWindow: presentingWindow
            ) { _ in
                alertWindow.makeFirstResponder(self.textView)
                if placeCursorAtEnd {
                    self.textView.setSelectedRange(
                        NSRange(location: self.textView.string.utf16.count, length: 0)
                    )
                }
            }
            guard response == .alertFirstButtonReturn else { return }

            do {
                let parsed = try Self.parse(textView.string)
                _ = workspace.setWorkspaceEnvironment(parsed)
                return
            } catch let error as ParseError {
                Self.presentInvalidEntryAlert(error, presentingWindow: presentingWindow)
            } catch {
                // `parse(_:)` currently exposes only ParseError. Keep the
                // editor open if that implementation detail ever changes.
                Self.presentInvalidEntryAlert(.invalidAssignment(line: 1), presentingWindow: presentingWindow)
            }
        }
    }

    /// Parses the editor's line-oriented representation.
    ///
    /// Blank lines and comment lines are ignored. The first `=` separates the
    /// key from the value, so additional equals signs remain part of the value.
    /// Empty values are rejected because the workspace sanitizer intentionally
    /// drops them; deleting the line is the unambiguous remove operation.
    nonisolated static func parse(_ text: String) throws -> [String: String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var environment: [String: String] = [:]

        for (offset, rawLine) in normalized.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" }
        ).enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { continue }

            guard let separator = line.firstIndex(of: "=") else {
                throw ParseError.invalidAssignment(line: lineNumber)
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...])
            guard !key.isEmpty else {
                throw ParseError.emptyKey(line: lineNumber)
            }
            guard !value.isEmpty else {
                throw ParseError.emptyValue(line: lineNumber)
            }
            guard !key.contains("\0"), !key.contains("=") else {
                throw ParseError.invalidKey(line: lineNumber)
            }
            guard !value.contains("\0") else {
                throw ParseError.invalidValue(line: lineNumber)
            }
            guard environment.updateValue(value, forKey: key) == nil else {
                throw ParseError.duplicateKey(line: lineNumber)
            }
        }

        return environment
    }

    private static func serializedEnvironment(_ environment: [String: String]) -> String {
        environment.keys.sorted().compactMap { key in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: "\n")
    }

    private static func makeTextView(initialText: String) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        textView.string = initialText
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 440,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        return textView
    }

    private static func makeAccessoryView(for textView: NSTextView) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        let scrollView = NSScrollView(frame: root.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        root.addSubview(scrollView)
        return root
    }

    private static func presentInvalidEntryAlert(
        _ error: ParseError,
        presentingWindow: NSWindow?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.workspaceEnvironment.invalid.title",
            defaultValue: "Invalid Workspace Environment"
        )
        let message = String(
            localized: "dialog.workspaceEnvironment.invalid.message",
            defaultValue: "Line %lld is not a valid environment entry. Use KEY=VALUE, with one variable per line."
        )
        alert.informativeText = String(format: message, Int64(error.line))
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: presentingWindow)
    }
}

extension Workspace {
    /// The single mutation path used by all workspace-environment UI actions.
    @discardableResult
    func setWorkspaceEnvironment(_ environment: [String: String]) -> Bool {
        let sanitized = Self.sanitizedWorkspaceEnvironment(environment)
        guard sanitized != workspaceEnvironment else { return false }
        workspaceEnvironment = sanitized
        return true
    }

    /// Includes environment contents in the session autosave fingerprint. The
    /// dictionary is sorted so equivalent dictionaries produce the same hash.
    func combineWorkspaceEnvironmentIntoSessionAutosaveFingerprint(into hasher: inout Hasher) {
        hasher.combine(workspaceEnvironment.count)
        for key in workspaceEnvironment.keys.sorted() {
            hasher.combine(key)
            hasher.combine(workspaceEnvironment[key] ?? "")
        }
    }

    func presentWorkspaceEnvironmentEditor() {
        WorkspaceEnvironmentEditor(workspace: self).present()
    }
}
