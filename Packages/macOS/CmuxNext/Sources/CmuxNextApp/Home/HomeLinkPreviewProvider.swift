import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextTabs
import MessagesLabHome
import CmuxNextCompat

/// What a Home link chip's target is now, for its hover card (plans/cmux-next/home-link-chips-DESIGN.md):
/// a workspace's name and tabs, a tab's title, place and (terminal) last lines or (page)
/// thumbnail, an agent chat's title, a file's first lines, a GitHub object's repository. A
/// target the app no longer has shows "Closed". It reads the models and never changes them.
final class HomeLinkPreviewProvider: HomeLinkPreviewing {
    private weak var services: AppServices?
    /// Lines a card shows at most.
    nonisolated static let maxLines = 6
    /// Bytes of a file read for its first lines.
    nonisolated static let fileBytes = 4096

    init(services: AppServices) {
        self.services = services
    }

    func preview(for url: URL, kind: HomeLinkChipKind) -> HomeLinkPreview {
        if url.isFileURL { return filePreview(url, kind: kind) }
        if url.scheme == "https" { return gitHubPreview(url, kind: kind) }
        guard let services,
              let link = CmuxAppLinks.link(for: url, linkScheme: services.linkScheme, chiefHost: services.agentTabs.chiefHost) else {
            return closed(kind, url.lastPathComponent)
        }
        switch link.target {
        case .workspace(let id):
            guard let workspace = services.machines.allWorkspaces.map(\.0).first(where: { $0.resourceID?.rawValue == id }) else {
                return closed(kind, id)
            }
            let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            let titles = TabTitleResolver(services: services)
            return HomeLinkPreview(kind: .workspace, title: workspace.displayName, place: HomeLinkPreviewStrings.tabCount(tabs.count),
                                   status: HomeLinkPreviewStrings.open, statusTone: .success,
                                   lines: tabs.prefix(Self.maxLines).map { titles.title($0) })
        case .pane(let id):
            guard let pane = services.pane(id: id), let tab = pane.tabs.first else { return closed(kind, id) }
            return tabPreview(tab, pane: pane, services: services)
        case .tab(let id):
            guard let (tab, pane) = Self.locate(id, in: services) else { return closed(kind, id) }
            return tabPreview(tab, pane: pane, services: services)
        case .session(let id, _):
            guard let key = services.agentTabs.tab(showing: id), let (tab, pane) = Self.locate(key, in: services) else { return closed(.session, id) }
            return tabPreview(tab, pane: pane, services: services, kind: .session)
        case .chiefSession(let home, let session):
            guard let key = services.agentTabs.tab(showing: session, host: "chief:" + home),
                  let (tab, pane) = Self.locate(key, in: services) else { return closed(.subagent, session) }
            return tabPreview(tab, pane: pane, services: services, kind: .subagent)
        case .agent(let harness, let session): // the tab an agent link reveals (DeepLinkNavigator), never a new one
            let shown = DeepLink.agentTabs(harness: harness, session: session, adopted: services.agentTabs.tab(resuming: AgentPaneAdopt(harness: harness, agentSessionId: session)), harnessSessions: services.machines.daemons.flatMap(\.store.reachableAgentHarnessSessions))
            guard let (tab, pane) = shown.lazy.compactMap({ Self.locate($0, in: services) }).first else { return closed(.session, session) }
            return tabPreview(tab, pane: pane, services: services, kind: .session)
        case .group(let id, let workspace):
            // A cloud group's record is in cmux Cloud; the card names the workspace when this Mac shows it.
            guard let workspace, let open = services.machines.allWorkspaces.map(\.0).first(where: { $0.resourceID?.rawValue == workspace }) else {
                return closed(kind, id)
            }
            let tabs = open.screens.flatMap(\.panes).flatMap(\.tabs)
            let titles = TabTitleResolver(services: services)
            return HomeLinkPreview(kind: .workspace, title: open.displayName, place: HomeLinkPreviewStrings.tabCount(tabs.count),
                                   status: HomeLinkPreviewStrings.open, statusTone: .success,
                                   lines: tabs.prefix(Self.maxLines).map { titles.title($0) })
        case .legacyWorkspace, .legacyPane, .legacySurface: return closed(kind, url.lastPathComponent)
        }
    }

    func details(for url: URL, preview: HomeLinkPreview) async -> HomeLinkPreview {
        var out = preview
        if url.isFileURL {
            let path = url.standardizedFileURL.path, kind = preview.kind
            // task-owner: one bounded read off the main thread; the card awaits it
            let lines = await Task.detached(priority: .userInitiated) { Self.firstLines(path, folder: kind == .folder) }.value
            if let lines { out.lines = lines; out.monospaced = kind == .code } else { out.status = HomeLinkPreviewStrings.closed; out.statusTone = .danger }
            return out
        }
        guard let services, let link = CmuxAppLinks.link(for: url, linkScheme: services.linkScheme, chiefHost: services.agentTabs.chiefHost) else { return out }
        let tabID: String? = switch link.target {
        case .tab(let id): id
        case .pane(let id): services.pane(id: id)?.tabs.first?.id
        default: nil
        }
        guard let tabID, let (tab, _) = Self.locate(tabID, in: services) else { return out }
        switch tab.kind {
        case .pty, .remoteTerminal:
            guard let connection = services.machines.daemon(forTab: tab).connection,
                  let screen = try? await connection.request(ReadScreenRequest(surface: tab.surface), timeout: .seconds(2)) else { return out }
            let lines = screen.text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            out.lines = Array(lines.filter { !$0.isEmpty }.suffix(Self.maxLines))
            out.monospaced = true
        case .browser:
            let image = await services.previews.previewImage(for: TabID(tab.id), maxPixelSize: CGSize(width: 600, height: 300))
            out.thumbnail = image
        default:
            break
        }
        return out
    }

    // MARK: Kinds

    private func tabPreview(_ tab: TabModel, pane: PaneModel, services: AppServices, kind chip: HomeLinkChipKind? = nil) -> HomeLinkPreview {
        let kind: HomeLinkChipKind
        var place = services.daemon(for: pane).store.workspace(containing: pane.handle)?.displayName
        if tab.agentSession != nil {
            kind = .session
        } else if tab.page == "markdown" {
            kind = .markdown
            place = tab.pageRoute.map(Self.abbreviated) ?? place
        } else if tab.page == "editor" {
            kind = .file
            place = tab.pageRoute.map(Self.abbreviated) ?? place
        } else {
            switch tab.kind {
            case .pty, .remoteTerminal:
                kind = .terminal
                if let cwd = tab.cwd { place = [place, Self.abbreviated(cwd)].compactMap { $0 }.joined(separator: " · ") }
            case .browser:
                kind = .browser
                place = tab.url ?? place
            default:
                kind = .tab
            }
        }
        return HomeLinkPreview(kind: chip ?? kind, title: TabTitleResolver(services: services).title(tab), place: place,
                               status: HomeLinkPreviewStrings.open, statusTone: .success)
    }

    private func filePreview(_ url: URL, kind: HomeLinkChipKind) -> HomeLinkPreview {
        let path = url.standardizedFileURL.path
        return HomeLinkPreview(kind: kind, title: (path as NSString).lastPathComponent,
                               place: Self.abbreviated((path as NSString).deletingLastPathComponent))
    }

    private func gitHubPreview(_ url: URL, kind: HomeLinkChipKind) -> HomeLinkPreview {
        let parts = url.path.split(separator: "/").map(String.init)
        let repo = parts.prefix(2).joined(separator: "/")
        let id = parts.last ?? ""
        let title = kind == .commit ? String(id.prefix(10)) : kind == .run ? id : "#" + id
        return HomeLinkPreview(kind: kind, title: title, place: repo)
    }

    private func closed(_ kind: HomeLinkChipKind, _ id: String) -> HomeLinkPreview {
        HomeLinkPreview(kind: kind, title: id, status: HomeLinkPreviewStrings.closed, statusTone: .danger)
    }

    /// The tab with durable id `id` and its pane, on any machine, for one card read.
    private static func locate(_ id: String, in services: AppServices) -> (TabModel, PaneModel)? {
        // view-observation-allow: locateTab is one MachineTabIndex lookup (p06-scheduler-051), read once per card; no scan, no observation
        services.locateTab(id)
    }

    /// `path` with the home folder as `~`.
    nonisolated static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A file's first non-empty lines (or a folder's first names); nil when it is gone.
    nonisolated static func firstLines(_ path: String, folder: Bool) -> [String]? {
        if folder {
            guard let names = try? FileManager.checked.contentsOfDirectory(atPath: path) else { return nil }
            return Array(names.filter { !$0.hasPrefix(".") }.sorted().prefix(maxLines))
        }
        guard let handle = try? FileHandle.blockingForReading(from: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.blockingRead(upToCount: fileBytes)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains("\u{0}") else { return [] }
        return Array(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(maxLines))
    }
}

/// The card's own words. Keys live in Resources/Localizable.xcstrings.
enum HomeLinkPreviewStrings {
    static var open: String { String(localized: "home.linkPreview.open", defaultValue: "Open", bundle: .module) }
    static var closed: String { String(localized: "home.linkPreview.closed", defaultValue: "Closed", bundle: .module) }
    static func tabCount(_ count: Int) -> String {
        String(format: String(localized: "home.linkPreview.tabCount", defaultValue: "Tabs: %lld", bundle: .module), count)
    }
}
