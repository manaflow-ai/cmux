import AppKit

/// A sheet that edits one of Chief's memory files (person.md or
/// instructions.md) in place: a plain text view, Cancel and Save. The file
/// is read when the sheet opens and written atomically on Save; Chief reads
/// it when its next conversation session starts.
@MainActor
final class ChiefMemoryEditor: NSObject {
    private let fileURL: URL
    private let sheet: NSWindow
    private let textView = NSTextView()
    private let status = NSTextField(labelWithString: "")
    /// Keeps the editor alive while its sheet shows.
    private static var open: Set<ChiefMemoryEditor> = []

    private init(title: String, fileURL: URL, text: String) {
        self.fileURL = fileURL
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init()
        sheet.title = title
        sheet.minSize = NSSize(width: 420, height: 300)
        let content = NSView()
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let path = NSTextField(labelWithString: (fileURL.path as NSString).abbreviatingWithTildeInPath)
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.isSelectable = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        status.isHidden = true
        let cancel = NSButton(title: ChiefStrings.memoryCancel, target: self, action: #selector(cancelEdit))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: ChiefStrings.memorySave, target: self, action: #selector(saveEdit))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        save.bezelStyle = .push
        for view in [heading, path, scroll, status, cancel, save] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            path.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            path.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            path.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -14),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            status.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -8),
        ])
        sheet.contentView = content
        sheet.defaultButtonCell = save.cell as? NSButtonCell
    }

    /// Opens `fileURL` in a sheet on `window` (a window of its own without one).
    static func present(title: String, fileURL: URL, in window: NSWindow?) {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let editor = ChiefMemoryEditor(title: title, fileURL: fileURL, text: text)
        open.insert(editor)
        if let window {
            window.beginSheet(editor.sheet)
        } else {
            editor.sheet.center()
            editor.sheet.makeKeyAndOrderFront(nil)
        }
        editor.sheet.makeFirstResponder(editor.textView)
    }

    @objc private func saveEdit() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(textView.string.utf8).write(to: fileURL, options: .atomic)
            close()
        } catch {
            status.stringValue = ChiefStrings.memorySaveFailed
            status.isHidden = false
            NSSound.beep()
        }
    }

    @objc private func cancelEdit() { close() }

    private func close() {
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.orderOut(nil)
        }
        Self.open.remove(self)
    }
}
