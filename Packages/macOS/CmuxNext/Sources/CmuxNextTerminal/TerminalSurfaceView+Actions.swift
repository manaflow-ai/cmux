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
        case .ringBell:
            model.bellCount += 1
            if let delegate = session.delegate {
                delegate.terminalSessionDidRingBell(session)
            } else {
                GhosttyRuntime.shared.bellSettings.ring()
            }
        case .openURL(let text):
            guard let url = Self.url(from: text) else { return false }
            if let delegate = session.delegate {
                return delegate.terminalSession(session, open: url)
            }
            return NSWorkspace.shared.open(url)
        case .mouseShape(let shape):
            setCursor(Self.cursor(for: shape))
        case .mouseVisible(let visible):
            if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
        case .mouseOverLink(let link):
            model.hoveredLink = link
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
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}
