import AppKit
import GhosttyNextKit

// Surface-targeted Ghostty actions (`action_cb`) applied to the session
// model or forwarded to the delegate.
extension TerminalSurfaceView {
    func handleHostAction(_ action: TerminalHostAction) -> Bool {
        guard let session else { return false }
        return session.delegate?.terminalSession(session, perform: action) ?? false
    }

    // swiftlint:disable:next cyclomatic_complexity
    func applyAction(_ action: GhosttyAction) -> Bool {
        guard let session else { return false }
        let model = session.model
        switch action {
        case .setTitle(let title):
            model.title = title
        case .pwd(let pwd):
            model.workingDirectory = pwd.isEmpty ? nil : pwd
            bridge.takeUnretainedValue().linkFilter.setWorkingDirectory(model.workingDirectory)
        case .ringBell:
            model.bellCount += 1
            if let delegate = session.delegate {
                delegate.terminalSessionDidRingBell(session)
            } else {
                GhosttyRuntime.shared.bellSettings.ring()
            }
        case .openURL(let text):
            if let delegate = session.delegate {
                return delegate.terminalSession(session, openLink: text)
            }
            guard let url = Self.url(from: text) else { return false }
            // Never the blocking open: Ghostty holds the renderer lock here.
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        case .mouseShape(let shape):
            // Over a link with Command held the hand stays (TerminalLinkPointer).
            let cursor = Self.cursor(for: shape)
            if !linkPointer.absorbsCursor(cursor) { setCursor(cursor) }
        case .mouseVisible(let visible):
            if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
        case .mouseOverLink(let link):
            // Sent on every pointer move over a link; only a change notifies.
            if model.hoveredLink != link { model.hoveredLink = link }
            if link == nil { linkPointer.linkLeft() }
        case .cellSize:
            // Font size changed: re-apply the announced grid at the new cell
            // size; an owner reports the grid the view now fits.
            updateSurfaceSize()
        case .rendererHealthy(let healthy):
            model.isRendererHealthy = healthy
        case .progress(let progress):
            model.progress = progress
        case .commandFinished(let result):
            model.lastCommand = result
        case .childExited:
            model.hasExited = true
        case .secureInput(let mode):
            TerminalSecureInput.apply(mode, for: self)
        case .readOnly(let readOnly):
            model.isReadOnly = readOnly
        case .keySequence(let active):
            model.isKeySequencePending = active
        case .backgroundColor(let red, let green, let blue):
            model.backgroundOverride = NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        case .scrollbar(let scrollbar):
            model.scrollbar = scrollbar
            // Output or a mouse scroll moved the viewport under the cursor box.
            copyMode.syncCursor()
        case .startSearch(let needle):
            session.find.searchStarted(needle: needle)
        case .endSearch:
            session.find.searchEnded()
        case .searchTotal(let total):
            session.find.receiveTotal(total)
        case .searchSelected(let selected):
            session.find.receiveSelected(selected)
        case .copyTitleToClipboard:
            guard !model.title.isEmpty else { return false }
            TerminalPasteboard.write([TerminalClipboardItem(mime: "text/plain", text: model.title)], to: .standard)
        case .render:
            // Metal draws from its own display link; nothing to schedule.
            return true
        case .host, .configChange, .reloadConfig, .openConfig:
            return false
        }
        return true
    }

    func surfaceRequestedClose() {
        guard let session else { return }
        session.delegate?.terminalSessionDidRequestClose(session)
    }

    /// Ghostty passes URLs and bare paths (from OSC 8 or link detection).
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard safeTerminalText(trimmed) else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                guard !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
                      safeTerminalURL(url), url.host?.isEmpty == false,
                      url.user == nil, url.password == nil else { return nil }
                return url
            }
            let host = url.host?.lowercased()
            guard scheme == "file", safeTerminalURL(url), url.user == nil, url.password == nil,
                  url.port == nil, url.query == nil, url.fragment == nil,
                  host == nil || host == "" || host == "localhost" else { return nil }
            return url
        }
        // The app delegate resolves bare paths off-main. A delegate-free host
        // has no machine provenance and must not stat or open them here while
        // Ghostty holds its renderer lock.
        return nil
    }

    private static func safeTerminalText(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) || invisibleFormat(scalar.value)
        }
    }

    private static func safeTerminalURL(_ url: URL) -> Bool {
        guard let decoded = url.absoluteString.removingPercentEncoding else { return false }
        return safeTerminalText(decoded)
    }

    private static func invisibleFormat(_ value: UInt32) -> Bool {
        value == 0x00AD || value == 0x061C || value == 0x180E
            || (0x200B...0x200F).contains(value) || (0x202A...0x202E).contains(value)
            || (0x2060...0x2064).contains(value) || (0x2066...0x206F).contains(value)
            || value == 0xFEFF || (0xFFF9...0xFFFB).contains(value)
    }
}
