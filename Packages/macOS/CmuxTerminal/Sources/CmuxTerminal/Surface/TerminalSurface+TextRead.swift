public import Foundation
internal import GhosttyKit
#if DEBUG
internal import CMUXDebugLog
#endif

// MARK: - Terminal-text snapshot readers

/// Snapshot-text readers that pull terminal contents out of a live Ghostty
/// surface.
///
/// These were previously methods on the app-target `TerminalController`; they
/// are byte-faithful relocations onto the ``TerminalSurface`` surface model,
/// which already owns the `ghostty_surface_t` pointer, the
/// `liveSurfaceForGhosttyAccess(reason:)` quarantine guard, and
/// `performBindingAction(_:)`. The pure payload assembly already lives in
/// ``TerminalTextPayload`` and `String.terminalTextTail`.
///
/// Two app-coupled inputs are passed in so the package stays free of
/// `AppDelegate`/`TerminalPanel` reach-ups:
/// - `pasteboard`: the shared ``TerminalPasteboardService`` whose
///   `captureNextStandardClipboardWrite(_:)` brackets the VT-export binding
///   action (the app injects `GhosttyApp.terminalPasteboard`).
/// - `performBindingAction`: a closure performing the Ghostty binding action,
///   so the caller can preserve panel-level guards (the agent-hibernation
///   guard in `TerminalPanel.performBindingAction(_:)`) that are not surface
///   state.
extension TerminalSurface {
    /// Reads the raw per-point terminal text for this surface.
    ///
    /// Returns `nil` when the surface pointer is absent. For a non-scrollback
    /// read only the viewport is populated; for a scrollback read the screen,
    /// history, and active reads are populated and the viewport is left `nil`,
    /// matching the legacy reader exactly.
    @MainActor
    public func readTextRawSnapshot(
        includeScrollback: Bool
    ) -> TerminalTextRawSnapshot? {
        guard surface != nil else { return nil }
        if includeScrollback {
            return TerminalTextRawSnapshot(
                viewport: nil,
                screen: readSelectionText(pointTag: GHOSTTY_POINT_SCREEN),
                history: readSelectionText(pointTag: GHOSTTY_POINT_SURFACE),
                active: readSelectionText(pointTag: GHOSTTY_POINT_ACTIVE)
            )
        }
        return TerminalTextRawSnapshot(
            viewport: readSelectionText(pointTag: GHOSTTY_POINT_VIEWPORT),
            screen: nil,
            history: nil,
            active: nil
        )
    }

    /// Reads the text spanning a full point-tag region of this surface, or `nil`
    /// when the surface pointer is absent or the read fails. An empty (but
    /// successful) read returns the empty string.
    @MainActor
    func readSelectionText(pointTag: ghostty_point_tag_e) -> String? {
        guard let surface = surface else { return nil }
        return Self.readText(surface: surface, pointTag: pointTag)
    }

    /// Reads the terminal text as a base64 payload string, prefixed with
    /// `"OK "` on success or `"ERROR: …"` on failure, matching the legacy v1/v2
    /// read response shape.
    @MainActor
    public func readTextBase64(
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String {
        guard liveSurfaceForGhosttyAccess(reason: "readTerminalTextBase64") != nil else {
            return "ERROR: Terminal surface not found"
        }
        guard let snapshot = readTextRawSnapshot(
            includeScrollback: includeScrollback
        ) else {
            return "ERROR: Terminal surface not found"
        }
        switch TerminalTextPayload.make(
            from: snapshot,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        ) {
        case .success(let payload):
            return "OK \(payload.base64)"
        case .failure(let error):
            return "ERROR: \(error.message)"
        }
    }

    /// Captures the terminal contents via Ghostty's VT-export binding action,
    /// reading back the file the action writes to the standard clipboard hook.
    ///
    /// `performBindingAction` performs the export so the caller keeps any
    /// panel-level guard (the agent-hibernation gate). Returns `nil` when the
    /// export path is unavailable or the file cannot be read.
    @MainActor
    public func readTextFromVTExportForSnapshot(
        pasteboard: TerminalPasteboardService,
        performBindingAction: () -> Bool,
        bindingAction: String = "write_screen_file:copy,vt",
        lineLimit: Int?,
        normalizeLineEndings: Bool = true
    ) -> String? {
        var actionSucceeded = false
        let exportedPath = pasteboard.captureNextStandardClipboardWrite {
            let ok = performBindingAction()
            actionSucceeded = ok
            return ok
        }
        #if DEBUG
        logDebugEvent("mobile.vtExport action=\(bindingAction) succeeded=\(actionSucceeded) hasPath=\(exportedPath != nil)")
        #endif
        guard let exportedPath = Self.normalizedExportedScreenPath(exportedPath) else {
            return nil
        }

        let fileURL = URL(fileURLWithPath: exportedPath)
        defer {
            if Self.shouldRemoveExportedScreenFile(fileURL: fileURL) {
                try? FileManager.default.removeItem(at: fileURL)
                if Self.shouldRemoveExportedScreenDirectory(fileURL: fileURL) {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              let rawOutput = String(data: data, encoding: .utf8) else {
            return nil
        }
        var output = normalizeLineEndings
            ? Self.normalizedMobileVTExportText(rawOutput)
            : rawOutput
        if let lineLimit {
            output = output.terminalTextTail(maxLines: lineLimit)
        }
        return output
    }

    /// Reads the terminal text by decoding the base64 read response into plain
    /// UTF-8 text, or `nil` when the read failed or the payload is malformed.
    @MainActor
    func readPlainTextForSnapshot(
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        let response = readTextBase64(
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
        guard response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.isEmpty {
            return ""
        }
        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    /// Reads the terminal text for a snapshot, preferring the VT-export path for
    /// scrollback reads when allowed and falling back to the plain base64 read.
    @MainActor
    public func readTextForSnapshot(
        pasteboard: TerminalPasteboardService,
        performBindingAction: () -> Bool,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil,
        allowVTExport: Bool = true
    ) -> String? {
        if includeScrollback,
           allowVTExport,
           let vtOutput = readTextFromVTExportForSnapshot(
               pasteboard: pasteboard,
               performBindingAction: performBindingAction,
               lineLimit: lineLimit
           ) {
            return vtOutput
        }

        return readPlainTextForSnapshot(
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    /// Reads the visible-tail terminal text for the periodic hibernation
    /// fingerprint. Samples the viewport only (no scrollback, no VT export) so
    /// the timer never copies full scrollback every cycle.
    @MainActor
    public func readTextForHibernationFingerprint(
        lineLimit: Int
    ) -> String? {
        // This runs from the periodic hibernation timer. Sample the visible tail
        // only, rather than copying full scrollback every cycle. VT export is
        // disabled, so no pasteboard/binding action is needed.
        readPlainTextForSnapshot(
            includeScrollback: false,
            lineLimit: lineLimit
        )
    }

    /// Reads the terminal text for a persisted session snapshot, using the same
    /// VT-export-then-plain path as ``readTextForSnapshot(pasteboard:performBindingAction:includeScrollback:lineLimit:allowVTExport:)``.
    @MainActor
    public func readTextForSessionSnapshot(
        pasteboard: TerminalPasteboardService,
        performBindingAction: () -> Bool,
        includeScrollback: Bool = false,
        lineLimit: Int? = nil
    ) -> String? {
        readTextForSnapshot(
            pasteboard: pasteboard,
            performBindingAction: performBindingAction,
            includeScrollback: includeScrollback,
            lineLimit: lineLimit
        )
    }

    // MARK: - VT-export path helpers (pure)

    /// Normalizes a raw exported-screen path (a `file://` URL or an absolute
    /// path) to an absolute filesystem path, or `nil` when the value is empty
    /// or not an absolute path.
    public nonisolated static func normalizedExportedScreenPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.isFileURL,
           !url.path.isEmpty {
            return url.path
        }
        return trimmed.hasPrefix("/") ? trimmed : nil
    }

    /// Whether the exported-screen file lives under the temporary directory and
    /// should therefore be cleaned up after reading.
    public nonisolated static func shouldRemoveExportedScreenFile(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let standardizedFile = fileURL.standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return standardizedFile.path.hasPrefix(temporary.path + "/")
    }

    /// Whether the exported-screen file's parent directory lives under the
    /// temporary directory and should be cleaned up after reading.
    public nonisolated static func shouldRemoveExportedScreenDirectory(
        fileURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let temporary = temporaryDirectory.standardizedFileURL
        return directory.path.hasPrefix(temporary.path + "/")
    }

    /// Normalizes Ghostty VT-export row separators (CRLF) to LF. Swift treats
    /// CRLF as one `Character`, so a naive `split(separator: "\n")` would miss
    /// rows; this rewrite makes the text line-splittable.
    public nonisolated static func normalizedMobileVTExportText(_ text: String) -> String {
        // Ghostty's VT formatter writes row separators as CRLF. Swift treats
        // CRLF as one Character, so split(separator: "\n") would miss rows.
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }
}
