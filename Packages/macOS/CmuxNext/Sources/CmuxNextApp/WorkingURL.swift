import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The dev server a terminal shows (#16620): the newest localhost URL on
/// screen, for a browser tab opened from it. Same rules as the agent pane's
/// `paneContext.ts`: `0.0.0.0` becomes `localhost`, trailing punctuation is
/// not part of the URL.
enum WorkingURL {
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    static func devServer(in text: String?) -> URL? {
        guard let text else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let links = detector?.matches(in: text, range: range).compactMap(\.url) ?? []
        for url in links.reversed() {
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host()?.lowercased(),
                  localHosts.contains(host) || host.hasSuffix(".localhost"),
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            if host == "0.0.0.0" { parts.host = "localhost" }
            while let last = parts.path.last, ".,;:!?".contains(last) { parts.path.removeLast() }
            return parts.url
        }
        return nil
    }

    /// An agent's cwd comes from its page: use it only as an absolute path
    /// to a directory on this Mac (a remote agent's folder is not one).
    static func isDirectory(_ path: String, fileManager: FileManager = .default) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && fileManager.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

extension PaneController {
    /// New Browser Tab without a URL opens what the selected tab works on
    /// (#16620): an agent's newest dev server or pull request (the page lists
    /// no other URLs), a terminal's
    /// dev server, else a blank tab.
    func newBrowserTabFromSelectedTab(engine: String?, then: (@MainActor (SurfaceID) -> Void)? = nil) {
        switch currentContent {
        case .agent(let view):
            services.registry.track(Task {
                let url = await view.workingContext()?.urls.first
                newBrowserTab(url: url, engine: engine, then: then)
                return nil
            })
        case .terminal(let entry):
            newBrowserTab(url: WorkingURL.devServer(in: entry.session.surfaceView.viewportText()), engine: engine, then: then)
        case .browser, .placeholder, nil:
            newBrowserTab(url: nil, engine: engine, then: then)
        }
    }

    /// The selected agent tab's page, whose chat a new terminal asks for its
    /// cwd; nil when another kind is selected.
    var selectedAgentView: AgentPaneView? {
        if case .agent(let view) = currentContent { return view }
        return nil
    }
}
