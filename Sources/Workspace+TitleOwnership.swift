import Foundation

/// Title and description ownership: which of the process title, the custom
/// title, and the custom description a workspace presents, who set them, and
/// how automatic process-title changes reach the sidebar's settled
/// observation stream.
extension Workspace {
    // MARK: - Title Management

    /// Who set a custom title. Auto-naming (AI-generated titles) must never
    /// overwrite a user-set title; this enum carries that distinction for
    /// workspace and panel custom titles, and round-trips through session
    /// persistence.
    enum CustomTitleSource: String, Codable, Sendable {
        case user
        case auto
    }

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    /// The provenance of the current custom title, normalizing legacy state:
    /// `nil` when no custom title is set; `.user` when a title exists but
    /// provenance was never recorded (pre-provenance snapshots, carried moves).
    var effectiveCustomTitleSource: CustomTitleSource? {
        hasCustomTitle ? (customTitleSource ?? .user) : nil
    }

    var hasCustomDescription: Bool {
        Self.normalizedCustomDescription(customDescription) != nil
    }

    func applyProcessTitle(_ title: String) {
        if processTitle != title {
            processTitle = title
        }
        guard customTitle == nil else { return }
        guard self.title != title else { return }
#if DEBUG
        cmuxDebugLog(
            "workspace.title.applyProcess workspace=\(id.uuidString.prefix(5)) " +
            "from=\"\(debugWorkspaceDescriptionPreview(self.title, limit: 80))\" " +
            "to=\"\(debugWorkspaceDescriptionPreview(title, limit: 80))\""
        )
#endif
        applyAutomaticTitle(title)
    }

    /// The single write path for automatic (non-user) workspace titles.
    /// Every mutation of `title` that does not come from a custom-title edit
    /// must go through here: the sidebar's settled observation stream only
    /// sees changes signaled at this chokepoint, and a writer that sets
    /// `title` directly leaves rows permanently stale (updatePanelTitle's
    /// single-panel branch did exactly that).
    func applyAutomaticTitle(_ title: String) {
        guard self.title != title else { return }
        self.title = title
        sidebarProcessTitleObservation.processTitleDidChange()
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, panels[panelId] != nil else { return false }
        var didMutate = false
        var didMutatePanelTitle = false
        var didMutateWorkspaceTitle = false

        if !isRemoteTmuxMirror, panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
            didMutatePanelTitle = true
        }

        if panels[panelId] is TerminalPanel,
           clearStaleAgentPIDs(panelId: panelId, refreshPorts: true) {
            didMutate = true
        }

        if didMutatePanelTitle,
           let tabId = surfaceIdFromPanelId(panelId),
           let panel = panels[panelId],
           let existing = bonsplitController.tab(tabId) {
            let baseTitle = panelTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let hasCustomTitle = panelCustomTitles[panelId] != nil
            if titleUpdate != nil || existing.hasCustomTitle != hasCustomTitle {
                bonsplitController.updateTab(
                    tabId,
                    title: titleUpdate,
                    hasCustomTitle: hasCustomTitle
                )
            }
        }

        if !isRemoteTmuxMirror, panels.count == 1, customTitle == nil {
            if self.title != trimmed {
                applyAutomaticTitle(trimmed)
                didMutate = true
                didMutateWorkspaceTitle = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

#if DEBUG
        if didMutate {
            cmuxDebugLog(
                "workspace.title.updatePanel workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) panels=\(panels.count) custom=\(customTitle == nil ? 0 : 1) " +
                "panelChanged=\(didMutatePanelTitle ? 1 : 0) workspaceChanged=\(didMutateWorkspaceTitle ? 1 : 0) " +
                "title=\"\(debugWorkspaceDescriptionPreview(trimmed, limit: 80))\""
            )
        }
#endif
        return didMutate
    }

    private static func normalizedCustomDescription(_ description: String?) -> String? {
        let normalizedLineEndings = description?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedLineEndings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return normalizedLineEndings
    }

    /// Sets, replaces, or clears (empty/nil `title`) the workspace custom title.
    ///
    /// `.auto` writes are rejected when a user-set title exists, and `.auto`
    /// never clears. Returns whether the write landed.
    @discardableResult
    func setCustomTitle(_ title: String?, source: CustomTitleSource = .user) -> Bool {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if source == .auto {
            guard !trimmed.isEmpty else { return false }
            if hasCustomTitle, (customTitleSource ?? .user) == .user { return false }
        }
        if trimmed.isEmpty {
            if customTitle != nil {
                sidebarProcessTitleObservation.cancelPendingProcessTitleChange()
            }
            customTitle = nil
            customTitleSource = nil
            self.title = processTitle
        } else {
            sidebarProcessTitleObservation.cancelPendingProcessTitleChange()
            customTitle = trimmed
            customTitleSource = source
            self.title = trimmed
        }
        return true
    }

    func setCustomDescription(_ description: String?) {
        let normalizedDescription = Self.normalizedCustomDescription(description)
#if DEBUG
        let inputNewlines = description?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        let normalizedNewlines = normalizedDescription?.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        } ?? 0
        cmuxDebugLog(
            "workspace.customDescription.update workspace=\(id.uuidString.prefix(8)) " +
            "inputLen=\((description as NSString?)?.length ?? 0) " +
            "inputNewlines=\(inputNewlines) " +
            "normalizedLen=\((normalizedDescription as NSString?)?.length ?? 0) " +
            "normalizedNewlines=\(normalizedNewlines) " +
            "input=\"\(debugWorkspaceDescriptionPreview(description))\" " +
            "normalized=\"\(debugWorkspaceDescriptionPreview(normalizedDescription))\""
        )
#endif
        customDescription = normalizedDescription
    }
}
