import CmuxNextActions
import CmuxNextLayout
import Foundation
import CmuxNextWakeups
import CmuxNextCompat

/// A click on a cmux app link in rendered Markdown (the Home transcript, an agent chat, a
/// Markdown file page) or a terminal: a path (`file:///…`, ``openPath(_:services:)``),
/// `cmux://workspace/<ws_…>`, `pane/<pane_…>`, `tab/<tab_…>`,
/// `session/<id>`, or a Chief subagent's `chief/<home id>/session/<id>` (optchat-chief
/// `workspaces::subagent_link`). The Chief and its documents write the `cmux` scheme whatever the
/// build, so the link is opened as this build's `link.open` (the one shared path) and never goes
/// to another app through the system: the plain `cmux` scheme belongs to the Release app.
enum CmuxAppLinks {
    /// Runs `link.open` on `url` when ``link(for:linkScheme:chiefHost:)`` accepts it; false
    /// (nothing runs) for any other URL.
    @MainActor
    @discardableResult
    static func open(_ url: URL, services: AppServices) -> Bool {
        if url.isFileURL { return openPath(url, services: services) }
        if let action = settingsAction(for: url, linkScheme: services.linkScheme) {
            return services.registry.perform(action, invocation: ActionInvocation(origin: .user))
        }
        guard let link = link(for: url, linkScheme: services.linkScheme, chiefHost: services.agentTabs.chiefHost),
              let text = link.url(scheme: services.linkScheme)?.absoluteString else { return false }
        return services.registry.perform("link.open", invocation: ActionInvocation(arguments: ["url": .string(text)], origin: .user))
    }

    /// A path link (`file:///…`: Home's form of a path an agent wrote): a file opens in the
    /// file pages, a folder in a terminal started there, both beside the focused pane
    /// (``LinkOpener``, which shows why a file cannot open). Never handed to the system. The disk check
    /// runs off the main thread, after the click returns. False for a URL that is no
    /// absolute file path.
    @MainActor
    static func openPath(_ url: URL, services: AppServices) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/") else { return false }
        let path = url.standardizedFileURL.path
        let work = services.work
        // task-owner: one disk check, then one open
        Task { @MainActor [weak services] in
            // A person clicked the link: the disk check runs on the files lane at userBlocking (a stalled volume
            // holds a lane thread, never a cooperative-pool one).
            let isDirectory = (try? await work.run(.userBlocking, mayBlock: .files) { () -> Bool in
                var directory: ObjCBool = false
                return FileManager.checked.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
            }) ?? false
            guard let services else { return }
            // Beside the pane the link was clicked from (LinkOpener): the pinned Home column, which
            // takes no tabs, gets the pane on its right or a new split.
            let source = services.windows.active?.focusedPane
            if isDirectory {
                services.linkOpener.openFolder(path, from: source)
            } else {
                services.linkOpener.openFile(URL(fileURLWithPath: path), from: source)
            }
        }
        return true
    }

    /// The action a settings link runs (``DeepLink/settingsAction(for:linkScheme:)``).
    static func settingsAction(for url: URL, linkScheme: String) -> ActionID? { DeepLink.settingsAction(for: url, linkScheme: linkScheme) }

    /// The link `url` opens in this app (``DeepLink/appLink(for:linkScheme:chiefHost:)``).
    static func link(for url: URL, linkScheme: String, chiefHost: String?) -> DeepLink? {
        DeepLink.appLink(for: url, linkScheme: linkScheme, chiefHost: chiefHost)
    }
}
