import CMUXAgentLaunch
import CmuxControlSocket
import Foundation

/// What `SessionSnapshotImportTrust` removed or held back from an imported
/// session file.
struct SessionSnapshotImportTrustReport: Equatable, Sendable {
    /// Terminals whose resume command will not run automatically: custom
    /// agent registrations, trusted-source resume bindings, and tmux start
    /// commands taken from the file.
    var heldBackResumeCount = 0
    /// Workspaces whose SSH/cloud connection, surface projections, or
    /// environment was dropped.
    var droppedRemoteWorkspaceCount = 0
    /// Browser panels whose URL, history entries, profile, or cloud/diff
    /// provenance was dropped.
    var sanitizedBrowserPanelCount = 0
    /// Terminals whose scrollback had terminal control strings removed.
    var sanitizedScrollbackCount = 0
    /// Terminals whose text box draft attachments were dropped.
    var droppedDraftAttachmentCount = 0
}

/// Restore policy for a session snapshot read from an arbitrary file
/// (`cmux restore-session --from <path>`).
///
/// A file can carry anything, so nothing in it may run automatically or
/// reach outside the restored windows. Mirrors, and is stricter than, the
/// policy for public CLI/socket-created surface resume bindings: layout,
/// working directories, text, and http(s) pages restore; command-bearing
/// state is either reconstructed by cmux from known values or kept for
/// manual restore only.
///
/// - Built-in agents (a known `RestorableAgentKind`, or a built-in Vault
///   registration id) are rebuilt from kind, session id, and working
///   directory only. Launch argv, permission mode, and registration content
///   from the file are discarded, so the resume command is the one cmux
///   generates. They auto-resume only when the working directory is an
///   existing local directory not flagged as needing remote trust.
/// - Custom agent registrations stay attached for manual restore, but the
///   terminal is marked as not running an agent so nothing auto-resumes.
/// - Resume bindings are marked as untrusted session-import bindings: the
///   approval store never matches them (not even an existing auto-approved
///   prefix) and never records approvals for them, so they only run through
///   `cmux restore --surface`. A hook binding already covered by a rebuilt
///   built-in agent is dropped.
/// - tmux start commands are dropped.
/// - Scrollback keeps text and SGR styling only; OSC (clipboard, notification,
///   hyperlink, title, cwd), DCS, APC, PM, SOS and other control sequences
///   are removed before replay.
/// - Text box draft attachments (hidden submission text) are dropped.
/// - Browser panels keep only http/https URLs and history entries, and lose
///   their profile, dev tools, diff-viewer and cloud provenance.
/// - Workspace SSH/cloud connections, surface projections, and workspace
///   environment variables are dropped (SSH options such as `ProxyCommand`
///   and variables such as `BASH_ENV` execute locally).
///
/// Snapshots read from another install's own session file (a channel import)
/// keep full trust and do not go through this.
enum SessionSnapshotImportTrust {
    /// Built-in Vault registrations, keyed by id. File content is never used
    /// for these; the app's own definition replaces it.
    static var builtInRegistrationsByID: [String: CmuxVaultAgentRegistration] {
        let builtIns: [CmuxVaultAgentRegistration] = [
            .builtInPi,
            .builtInOmp,
            .builtInCampfire,
            .builtInAmp,
            .builtInAntigravity,
            .builtInGrok,
            .builtInKimi,
            .builtInHermes,
        ]
        return Dictionary(builtIns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The snapshot to restore for an import from `source`: unchanged for
    /// another install's own session file, sanitized for an arbitrary file.
    static func snapshotForRestore(
        _ snapshot: AppSessionSnapshot,
        source: ControlSessionImportSource
    ) -> (snapshot: AppSessionSnapshot, report: SessionSnapshotImportTrustReport) {
        source.isTrusted
            ? (snapshot, SessionSnapshotImportTrustReport())
            : sanitizingUntrustedImport(snapshot)
    }

    static func sanitizingUntrustedImport(
        _ snapshot: AppSessionSnapshot,
        isExistingDirectory: (String) -> Bool = Self.isExistingLocalDirectory
    ) -> (snapshot: AppSessionSnapshot, report: SessionSnapshotImportTrustReport) {
        var report = SessionSnapshotImportTrustReport()
        var sanitized = snapshot
        let builtIns = builtInRegistrationsByID
        func sanitize(_ panels: [SessionPanelSnapshot]) -> [SessionPanelSnapshot] {
            panels.map {
                sanitizedPanel($0, builtIns: builtIns, isExistingDirectory: isExistingDirectory, report: &report)
            }
        }
        for windowIndex in sanitized.windows.indices {
            var window = sanitized.windows[windowIndex]
            for workspaceIndex in window.tabManager.workspaces.indices {
                var workspace = window.tabManager.workspaces[workspaceIndex]
                if workspace.remote != nil || workspace.cloudVM != nil
                    || workspace.environment?.isEmpty == false
                    || workspace.surfaceProjections?.isEmpty == false {
                    report.droppedRemoteWorkspaceCount += 1
                }
                workspace.remote = nil
                workspace.cloudVM = nil
                workspace.environment = nil
                workspace.surfaceProjections = nil
                workspace.panels = sanitize(workspace.panels)
                if var dock = workspace.dock {
                    dock.panels = sanitize(dock.panels)
                    workspace.dock = dock
                }
                window.tabManager.workspaces[workspaceIndex] = workspace
            }
            if var dock = window.dock {
                dock.panels = sanitize(dock.panels)
                window.dock = dock
            }
            sanitized.windows[windowIndex] = window
        }
        return (sanitized, report)
    }

    static func isExistingLocalDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func sanitizedPanel(
        _ panel: SessionPanelSnapshot,
        builtIns: [String: CmuxVaultAgentRegistration],
        isExistingDirectory: (String) -> Bool,
        report: inout SessionSnapshotImportTrustReport
    ) -> SessionPanelSnapshot {
        var panel = panel
        if let browser = panel.browser {
            let (sanitizedBrowser, changed) = sanitizedBrowserPanel(browser)
            panel.browser = sanitizedBrowser
            if changed { report.sanitizedBrowserPanelCount += 1 }
        }
        guard var terminal = panel.terminal else { return panel }
        var heldBack = false

        var rebuiltAgent: SessionRestorableAgentSnapshot?
        if let agent = terminal.agent {
            if let rebuilt = rebuiltBuiltInAgent(agent, builtIns: builtIns) {
                rebuiltAgent = rebuilt
                terminal.agent = rebuilt
                // Only launch the agent automatically in a directory the user
                // already has locally and that no remote-trust rule flags.
                let cwd = rebuilt.workingDirectory ?? terminal.workingDirectory
                let cwdIsSafe = cwd.map(isExistingDirectory) == true
                    && panel.directoryRequiresRemoteTrust != true
                    && terminal.isRemoteTerminal != true
                if !cwdIsSafe {
                    heldBack = heldBack || terminal.wasAgentRunning != false
                    terminal.wasAgentRunning = false
                }
            } else {
                // Custom registration or an unsafe session id: keep it for
                // manual restore, never auto-resume it.
                heldBack = heldBack || terminal.wasAgentRunning != false
                terminal.wasAgentRunning = false
            }
        }

        let (binding, bindingHeldBack) = sanitizedBinding(terminal.resumeBinding, coveredBy: rebuiltAgent)
        terminal.resumeBinding = binding
        let (managed, managedHeldBack) = sanitizedBinding(terminal.managedAgentResumeBinding, coveredBy: rebuiltAgent)
        terminal.managedAgentResumeBinding = managed
        heldBack = heldBack || bindingHeldBack || managedHeldBack

        if terminal.tmuxStartCommand != nil {
            terminal.tmuxStartCommand = nil
            heldBack = true
        }
        if heldBack {
            report.heldBackResumeCount += 1
        }

        if let scrollback = terminal.scrollback {
            let stripped = strippingTerminalControlStrings(scrollback)
            if stripped != scrollback {
                report.sanitizedScrollbackCount += 1
            }
            terminal.scrollback = stripped
        }

        if let draft = terminal.textBoxDraft {
            let textParts = draft.parts.filter { $0.kind == .text }
            if textParts.count != draft.parts.count {
                report.droppedDraftAttachmentCount += 1
            }
            terminal.textBoxDraft = textParts.isEmpty
                ? nil
                : SessionTextBoxInputDraftSnapshot(isActive: draft.isActive, parts: textParts)
        }

        panel.terminal = terminal
        return panel
    }

    /// Whether a session id is a plain token cmux can pass as one argument:
    /// letters, digits, `_` and `-`, with single dots between segments. Rejects
    /// empty values, leading dots or hyphens, `..`, `:`, `+`, and path
    /// separators.
    static func isSafeSessionID(_ sessionId: String) -> Bool {
        sessionId.range(
            of: "^[A-Za-z0-9_][A-Za-z0-9_-]*(\\.[A-Za-z0-9_-]+)*$",
            options: .regularExpression
        ) != nil && AgentRestoreCLIArgument(rawValue: sessionId) != nil
    }

    /// Rebuilds a built-in agent from its kind, session id, and working
    /// directory only, or returns nil when the agent is not built-in or its
    /// session id is not a plain token.
    static func rebuiltBuiltInAgent(
        _ agent: SessionRestorableAgentSnapshot,
        builtIns: [String: CmuxVaultAgentRegistration] = builtInRegistrationsByID
    ) -> SessionRestorableAgentSnapshot? {
        guard isSafeSessionID(agent.sessionId) else { return nil }
        let registration: CmuxVaultAgentRegistration?
        if let fileRegistration = agent.registration {
            guard let builtIn = builtIns[fileRegistration.id],
                  agent.kind.rawValue == builtIn.id else {
                return nil
            }
            registration = builtIn
        } else {
            if case .custom(let id) = agent.kind {
                guard let builtIn = builtIns[id] else { return nil }
                registration = builtIn
            } else {
                registration = nil
            }
        }
        return SessionRestorableAgentSnapshot(
            kind: agent.kind,
            sessionId: agent.sessionId,
            workingDirectory: agent.workingDirectory,
            launchCommand: nil,
            registration: registration
        )
    }

    /// Marks a file-provided binding as an untrusted session import. Returns
    /// the binding to keep (nil when a rebuilt built-in agent already covers
    /// it) and whether it could otherwise have run automatically.
    private static func sanitizedBinding(
        _ binding: SurfaceResumeBindingSnapshot?,
        coveredBy rebuiltAgent: SessionRestorableAgentSnapshot?
    ) -> (SurfaceResumeBindingSnapshot?, Bool) {
        guard let binding else { return (nil, false) }
        if binding.isAgentHookBinding,
           let rebuiltAgent,
           binding.checkpointId == rebuiltAgent.sessionId,
           binding.kind == nil || binding.kind == rebuiltAgent.kind.rawValue {
            return (nil, false)
        }
        // Any binding could match an existing approved prefix, so every one
        // counts as held back.
        return (binding.markingUntrustedSessionImport(), true)
    }

    /// Removes the browser state an imported file must not control.
    static func sanitizedBrowserPanel(
        _ browser: SessionBrowserPanelSnapshot
    ) -> (SessionBrowserPanelSnapshot, changed: Bool) {
        var sanitized = browser
        sanitized.urlString = browser.urlString.flatMap { isAllowedImportedURL($0) ? $0 : nil }
        sanitized.backHistoryURLStrings = browser.backHistoryURLStrings?.filter(isAllowedImportedURL)
        sanitized.forwardHistoryURLStrings = browser.forwardHistoryURLStrings?.filter(isAllowedImportedURL)
        sanitized.profileID = nil
        sanitized.cloudResource = nil
        sanitized.diffViewerToken = nil
        sanitized.diffViewerRequestPath = nil
        sanitized.transparentBackground = nil
        sanitized.developerToolsVisible = false
        let changed = sanitized.urlString != browser.urlString
            || sanitized.backHistoryURLStrings != browser.backHistoryURLStrings
            || sanitized.forwardHistoryURLStrings != browser.forwardHistoryURLStrings
            || browser.profileID != nil
            || browser.cloudResource != nil
            || browser.diffViewerToken != nil
            || browser.diffViewerRequestPath != nil
            || browser.transparentBackground != nil
            || browser.developerToolsVisible
        return (sanitized, changed)
    }

    static func isAllowedImportedURL(_ string: String) -> Bool {
        guard let scheme = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    /// Keeps printable text, tabs, newlines, and SGR styling (`CSI … m`).
    /// Drops OSC, DCS, APC, PM, and SOS strings (7-bit and C1 forms), every
    /// other CSI or escape sequence, and remaining C0/C1 control characters,
    /// so replayed history cannot write the clipboard (OSC 52), post
    /// notifications (OSC 9/777), set hyperlinks or titles (OSC 8/0/2), report
    /// a cwd (OSC 7), or trigger terminal replies.
    static func strippingTerminalControlStrings(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        let esc: UInt32 = 0x1B

        /// Skips a control string body starting at `start` up to and including
        /// its terminator (ST as `ESC \` or C1 0x9C; BEL also ends OSC).
        func skipControlString(from start: Int, allowsBEL: Bool) -> Int {
            var cursor = start
            while cursor < scalars.count {
                let value = scalars[cursor].value
                if value == 0x9C { return cursor + 1 }
                if allowsBEL && value == 0x07 { return cursor + 1 }
                if value == esc, cursor + 1 < scalars.count, scalars[cursor + 1] == "\\" {
                    return cursor + 2
                }
                cursor += 1
            }
            return cursor
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let value = scalar.value
            if value == esc {
                guard index + 1 < scalars.count else { index += 1; continue }
                let next = scalars[index + 1]
                switch next {
                case "]":
                    index = skipControlString(from: index + 2, allowsBEL: true)
                case "P", "_", "^", "X":
                    index = skipControlString(from: index + 2, allowsBEL: false)
                case "[":
                    // CSI: parameters/intermediates 0x20-0x3F, final 0x40-0x7E.
                    var cursor = index + 2
                    while cursor < scalars.count, (0x20...0x3F).contains(scalars[cursor].value) {
                        cursor += 1
                    }
                    guard cursor < scalars.count else { index = cursor; continue }
                    let final = scalars[cursor]
                    let parameters = scalars[(index + 2)..<cursor]
                    let isSGR = final == "m"
                        && parameters.allSatisfy { ("0"..."9").contains($0) || $0 == ";" || $0 == ":" }
                    if isSGR {
                        output.append(contentsOf: scalars[index...cursor])
                    }
                    index = cursor + 1
                default:
                    // Other escape sequences: drop ESC, any intermediates, and the final byte.
                    var cursor = index + 1
                    while cursor < scalars.count, (0x20...0x2F).contains(scalars[cursor].value) {
                        cursor += 1
                    }
                    index = min(cursor + 1, scalars.count)
                }
                continue
            }
            switch value {
            case 0x9D:
                index = skipControlString(from: index + 1, allowsBEL: true)
            case 0x90, 0x98, 0x9E, 0x9F:
                index = skipControlString(from: index + 1, allowsBEL: false)
            case 0x09, 0x0A, 0x0D:
                output.append(scalar)
                index += 1
            case 0x00...0x1F, 0x7F...0x9F:
                index += 1
            default:
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }
}
