import AppKit
import Foundation

extension MarkdownPanel {
    func observeNoteRelocations() {
        relocationObserver = NotificationCenter.default.addObserver(
            forName: .cmuxNoteFileRelocated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let oldPath = notification.userInfo?["oldPath"] as? String,
                  let newPath = notification.userInfo?["newPath"] as? String else { return }
            Task { @MainActor in
                self?.followRelocation(from: oldPath, to: newPath)
            }
        }
    }

    private func followRelocation(from oldPath: String, to newPath: String) {
        guard !isClosed else { return }
        let current = (filePath as NSString).standardizingPath
        let remapped: String
        if current == oldPath {
            remapped = newPath
        } else if current.hasPrefix(oldPath + "/") {
            remapped = newPath + current.dropFirst(oldPath.count)
        } else {
            return
        }
        filePath = remapped
        if noteBodyPath != nil {
            // Persisted bodyPath stays in its index-relative form (relative to
            // `<projectRoot>/.cmux`) so session restore resolves it against the
            // restored project root instead of pinning this machine's absolute
            // path.
            if let range = remapped.range(of: "/.cmux/", options: .backwards) {
                noteBodyPath = String(remapped[range.upperBound...])
            } else {
                noteBodyPath = remapped
            }
        }
        displayTitle = (remapped as NSString).lastPathComponent
        // Re-read from the new location (keeping any unsaved editor buffer)
        // and re-arm the watcher there; future saves also land at the new path.
        loadFileContent(replacingDirtyContent: false)
        startWatching()
    }

    /// Follow Notes-tree renames of index-owned notes (a record retitle; the
    /// body file does not move) so a panel open on the note shows the new
    /// title in its tab instead of the stale open-time one.
    func observeNoteRetitles() {
        retitleObserver = NotificationCenter.default.addObserver(
            forName: .cmuxNoteRetitled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let bodyPath = notification.userInfo?["bodyPath"] as? String,
                  let title = notification.userInfo?["title"] as? String else { return }
            Task { @MainActor in
                self?.followRetitle(bodyPath: bodyPath, title: title)
            }
        }
    }

    private func followRetitle(bodyPath: String, title: String) {
        guard !isClosed, noteSlug != nil,
              (filePath as NSString).standardizingPath == bodyPath else { return }
        noteTitle = title
        displayTitle = title
    }

    /// Rename this note from its editor header (the Google-Docs-style title
    /// field). Routes through `CmuxNoteStore.retitle` — the same record
    /// mutation the Notes tree uses — then posts `.cmuxNoteRetitled` so this
    /// panel, any sibling panels on the same note, and the tree (via its
    /// `.cmux/notes` watcher on `index.json`) all adopt the new title.
    func renameNoteTitle(_ rawTitle: String) {
        guard !isClosed, let slug = noteSlug else { return }
        let bodyPath = (filePath as NSString).standardizingPath
        guard let projectRoot = NoteSupport.projectRoot(forNotePath: bodyPath) else { return }
        Task.detached(priority: .userInitiated) {
            guard let record = try? CmuxNoteStore.retitle(
                slug: slug, projectRoot: projectRoot, title: rawTitle
            ) else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .cmuxNoteRetitled,
                    object: nil,
                    userInfo: ["bodyPath": bodyPath, "title": record.title]
                )
            }
        }
    }

    /// True for paths inside a TRUSTED `.cmux/notes` tree (the per-workspace
    /// Notes filesystem). Note classification turns on implicit writes
    /// (debounced autosave and the close flush), so a bare substring match is
    /// not enough: the project-controlled root components must not be
    /// symlinks, the file itself must not be one, and the canonical path must
    /// stay inside the notes root — otherwise a committed link like
    /// `.cmux/notes/x.md -> ~/.zshrc` would get silently autosaved through.
    static func isWorkspaceNotesPath(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard let projectRoot = NoteSupport.projectRoot(forNotePath: standardized) else { return false }
        guard NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) else { return false }
        let fm = FileManager.default
        if ((try? fm.attributesOfItem(atPath: standardized))?[.type] as? FileAttributeType)
            == .typeSymbolicLink {
            return false
        }
        let notesRoot = ((NoteSupport.notesDirectory(forProjectRoot: projectRoot) as NSString)
            .standardizingPath as NSString).resolvingSymlinksInPath
        let canonical = (standardized as NSString).resolvingSymlinksInPath
        guard canonical.hasPrefix(notesRoot + "/") else { return false }
        // Same body restrictions as CmuxNoteStore.absoluteBodyPath: note
        // behavior may only ever attach to visible `.md` bodies — never the
        // notes root itself, cmux metadata (`index.json`, tree markers), or
        // hidden components — otherwise opening `.cmux/notes/index.json` in a
        // markdown panel would autosave over the note index.
        let relative = canonical.dropFirst(notesRoot.count + 1)
            .split(separator: "/").map(String.init)
        return !relative.isEmpty
            && relative.allSatisfy { !CmuxNoteStore.isDisallowedBodyComponent($0) }
            && relative[relative.count - 1].lowercased().hasSuffix(".md")
    }

    /// Adopt a changed typography default (from another viewer's "Set as Default"
    /// or a `cmux.json` reload), but only while this viewer still matches the
    func setDisplayMode(_ mode: MarkdownPanelDisplayMode, focusTextEditor: Bool = true) {
        guard displayMode != mode else {
            if mode == .text, focusTextEditor {
                focus()
            }
            return
        }
        displayMode = mode
        if mode == .text, focusTextEditor {
            focus()
        } else if mode != .text {
            pendingTextViewFocus = false
        }
    }

    func markAsProjectNote(
        slug: String,
        id: String? = nil,
        bodyPath: String? = nil,
        title: String? = nil
    ) {
        noteSlug = slug
        noteID = id
        noteBodyPath = bodyPath
        noteTitle = title
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedTitle, !resolvedTitle.isEmpty {
            displayTitle = resolvedTitle
        } else {
            displayTitle = slug
        }
    }

    func attachTextView(_ textView: NSTextView) {
        self.textView = textView
    }

    func retryPendingFocus() {
        guard pendingTextViewFocus else { return }
        focus()
    }

    func applySearchNeedle(_ needle: String) {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSearchNeedle = trimmed
        setDisplayMode(.text)
        applyPendingSearchNeedleIfPossible()
    }

    /// True when this panel is a project note (opened through the note path).
    /// Notes auto-save; plain Markdown files keep the explicit Save control.
    var isProjectNote: Bool { noteSlug != nil }

    /// Note-behavior gate (auto-save, flush-on-close, no manual Save control):
    /// flat slug-indexed project notes plus Notes-tree files.
    var behavesAsNote: Bool { isProjectNote || isWorkspaceNotesFile }

    func updateTextContent(_ nextContent: String) {
        guard textContent != nextContent else { return }
        textContent = nextContent
        content = nextContent
        isDirty = nextContent != originalTextContent
        GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
        scheduleAutoSaveIfNeeded()
    }

    /// Debounced auto-save for notes: write to disk shortly after the last
    /// keystroke so a note never needs a manual Save. No-op for plain Markdown.
    private func scheduleAutoSaveIfNeeded() {
        guard behavesAsNote, isDirty else { return }
        autoSaveTask?.cancel()
        let clock = autoSaveClock
        autoSaveTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.isDirty, !self.isClosed else { return }
            self.saveTextContent()
        }
    }

    @discardableResult
    func loadTextContent(replacingDirtyContent: Bool = true) -> Task<Void, Never>? {
        loadFileContent(replacingDirtyContent: replacingDirtyContent)
        return nil
    }

    @discardableResult
    func saveTextContent() -> Task<Void, Never>? {
        guard !isSaving else { return nil }
        let currentContent = textView?.string ?? textContent
        guard currentContent != originalTextContent else {
            textContent = currentContent
            content = currentContent
            isDirty = false
            GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
            return nil
        }

        saveGeneration += 1
        let generation = saveGeneration
        textContent = currentContent
        content = currentContent
        isDirty = true
        isSaving = true
        activeSaveGeneration = generation
        GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
        let savePath = (filePath as NSString).standardizingPath
        let fileURL = URL(fileURLWithPath: savePath)
        let encoding = textEncoding

        let requiresTrustedNoteWrite = behavesAsNote
        let task = Task {
            [weak self, currentContent, fileURL, encoding, generation, savePath, requiresTrustedNoteWrite] in
            let result: FilePreviewTextSaver.Result
            if requiresTrustedNoteWrite {
                result = await FilePreviewTextSaver.saveTrustedWorkspaceNote(
                    content: currentContent, to: fileURL, encoding: encoding
                )
            } else {
                result = await FilePreviewTextSaver.save(content: currentContent, to: fileURL, encoding: encoding)
            }
            guard let self, self.activeSaveGeneration == generation else { return }
            guard (self.filePath as NSString).standardizingPath == savePath else {
                self.activeSaveGeneration = nil
                self.isSaving = false
                self.isDirty = true
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
                if self.isClosed {
                    _ = self.saveTextContent()
                } else {
                    self.scheduleAutoSaveIfNeeded()
                }
                return
            }
            self.activeSaveGeneration = nil
            self.isSaving = false
            switch result {
            case .saved:
                self.originalTextContent = currentContent
                self.isDirty = self.textContent != currentContent
                self.isFileUnavailable = false
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
                // Edits made while this save was in flight leave isDirty == true.
                // If the panel is closing, the debounced autosave won't run, so flush
                // the latest text now — this write is ordered after the one that just
                // finished, so the newest content wins. Otherwise reschedule so autosave
                // continues without waiting for a new keystroke.
                if self.isDirty {
                    if self.isClosed {
                        _ = self.saveTextContent()
                    } else {
                        self.scheduleAutoSaveIfNeeded()
                    }
                }
            case .failed(let fileExists):
                self.isFileUnavailable = !fileExists
                GlobalSearchCoordinator.shared.captureMarkdownPanel(self)
            }
        }
        activeSaveTask = task
        return task
    }
}
