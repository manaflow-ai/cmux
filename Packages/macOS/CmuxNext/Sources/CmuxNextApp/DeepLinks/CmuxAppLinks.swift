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
    /// The scheme the Chief writes.
    static let chiefScheme = "cmux"

    /// Runs `link.open` on `url` when ``link(for:linkScheme:chiefHost:)`` accepts it; false
    /// (nothing runs) for any other URL.
    @MainActor
    @discardableResult
    static func open(_ url: URL, services: AppServices) -> Bool {
        if url.isFileURL { return openPath(url, services: services) }
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

    /// The link `url` opens in this app, in the `cmux` scheme or `linkScheme` (this build's): a
    /// workspace, pane, tab, chat session or outside agent session; a Chief subagent's chat only for this app's own
    /// Chief home (`chiefHost`, `chief:<home id>`) and on this machine. Nil for anything else (an
    /// unknown scheme or host, a malformed id, a legacy UUID link, another Chief's subagent).
    static func link(for url: URL, linkScheme: String, chiefHost: String?) -> DeepLink? {
        // A cloud group's https form (`https://cloud-api.cmux.dev/g/grp_…`) opens here too.
        guard let link = DeepLink.parse(url, scheme: chiefScheme) ?? DeepLink.parse(url, scheme: linkScheme)
            ?? DeepLink.parseGroupWeb(url) else { return nil }
        switch link.target {
        case .workspace, .pane, .tab, .session, .agent, .group:
            return link
        case .chiefSession(let home, _):
            return link.machine == nil && chiefHost == "chief:" + home ? link : nil
        case .legacyWorkspace, .legacyPane, .legacySurface:
            return nil
        }
    }
}
