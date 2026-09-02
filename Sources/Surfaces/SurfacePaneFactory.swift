import Bonsplit
import CmuxControlSocket
import Foundation
import WebKit

/// The one place that turns a ``SurfaceDestination`` into a pane. Providers call it to
/// materialize a projection; it maps the destination onto the same `surface.split` /
/// `surface.create` machinery the CLI uses, so a drop from the sidebar lands exactly where a
/// drop of a Vault session or a file would.
///
/// Focus policy (`cmux-socket-policy`): `focus: false` never activates the app, raises a
/// window, or moves selection; the pane is created quietly behind the current focus.
@MainActor
enum SurfacePaneFactory {
    enum FactoryError: Error, LocalizedError {
        case workspaceNotFound(UUID)
        case paneNotFound(String)
        case creationFailed(String)

        var errorDescription: String? {
            switch self {
            case .workspaceNotFound(let id): return "Workspace \(id.uuidString) was not found."
            case .paneNotFound(let id): return "Pane \(id) was not found."
            case .creationFailed(let detail): return "Could not create the pane: \(detail)"
            }
        }
    }

    /// A terminal pane running `initialCommand` (nil → the login shell) at the destination.
    static func makeTerminalPane(
        initialCommand: String?,
        workingDirectory: String?,
        at destination: SurfaceDestination,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        try create(typeRaw: "terminal", url: nil, initialCommand: initialCommand, workingDirectory: workingDirectory, at: destination, focus: focus)
    }

    /// A browser pane loading `url` at the destination.
    static func makeBrowserPane(url: URL, at destination: SurfaceDestination, focus: Bool) throws -> (workspaceID: UUID, panelID: UUID) {
        try create(typeRaw: "browser", url: url.absoluteString, initialCommand: nil, workingDirectory: nil, at: destination, focus: focus)
    }

    /// The URL a browser pane opens with when its real URL is still being resolved; the
    /// caller fills the pane with ``SurfaceBrowserPlaceholder`` content and navigates later.
    static let blankURL = URL(string: "about:blank")!

    /// The browser pane behind a projection, if it still exists and is a browser.
    static func browserPanel(panelID: UUID, in workspaceID: UUID) -> BrowserPanel? {
        workspace(id: workspaceID)?.panels[panelID] as? BrowserPanel
    }

    /// Sends an existing browser pane to `url` — the optimistic pane's second step, once
    /// the provider has its endpoint. A pane the person already closed is a no-op.
    static func navigate(panelID: UUID, in workspaceID: UUID, to url: URL) {
        guard let browser = browserPanel(panelID: panelID, in: workspaceID) else { return }
        _ = browser.navigate(to: url)
    }

    /// Fills an existing browser pane with local HTML (a connecting or failure screen).
    static func showPlaceholder(_ html: String, panelID: UUID, in workspaceID: UUID) {
        guard let browser = browserPanel(panelID: panelID, in: workspaceID) else { return }
        browser.webView.loadHTMLString(html, baseURL: nil)
    }

    /// Selects the workspace and focuses the pane, the way `surface.focus` does — an explicit
    /// focus-intent operation that still never activates the app.
    static func focus(panelID: UUID, in workspaceID: UUID) {
        _ = TerminalController.shared.controlSurfaceFocus(routing: routing(workspaceID: workspaceID), surfaceID: panelID)
    }

    /// Closes a pane (a restored placeholder that a provider replaced).
    static func close(panelID: UUID, in workspaceID: UUID) {
        _ = TerminalController.shared.controlSurfaceClose(routing: routing(workspaceID: workspaceID), surfaceID: panelID, hasSurfaceIDParam: true)
    }

    /// A fresh local workspace (⌘N) titled `title`, returned with the id of the starter
    /// pane it opened with so a caller projecting a group can take that pane's place.
    static func createLocalWorkspace(title: String) throws -> (workspaceID: UUID, starterPanelID: UUID?) {
        guard let workspace = AppDelegate.shared?.addWorkspaceInPreferredMainWindow(
            title: title,
            shouldBringToFront: false,
            debugSource: "surface.catalog.newWorkspace"
        ) else {
            throw FactoryError.workspaceNotFound(UUID())
        }
        return (workspace.id, workspace.focusedPanelId)
    }

    /// The pane (Bonsplit id) that hosts a panel, for re-projecting in place.
    static func paneID(ofPanel panelID: UUID, in workspaceID: UUID) -> String? {
        guard let workspace = workspace(id: workspaceID) else { return nil }
        return workspace.paneId(forPanelId: panelID)?.id.uuidString
    }

    // MARK: - internals

    private static func routing(workspaceID: UUID) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspaceID,
            surfaceID: nil,
            paneID: nil
        )
    }

    private static func workspace(id: UUID) -> Workspace? {
        AppDelegate.shared?.tabManagerFor(tabId: id)?.tabs.first { $0.id == id }
    }

    /// The surface a split is anchored on: the selected panel of the target pane.
    private static func anchorSurface(paneID: String, in workspace: Workspace) throws -> UUID {
        guard let uuid = UUID(uuidString: paneID) else { throw FactoryError.paneNotFound(paneID) }
        // Resolve the pane the way every socket command does: Bonsplit owns the PaneID
        // values, so look the UUID up among the workspace's live panes instead of
        // synthesizing one.
        guard let located = TerminalController.shared.v2LocatePane(uuid), located.workspace.id == workspace.id,
              let selected = workspace.selectedPanelForPaneDrop(in: located.paneId) else {
            throw FactoryError.paneNotFound(paneID)
        }
        return selected.panelId
    }

    private static func create(
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        at destination: SurfaceDestination,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let workspaceID = destination.workspaceID
        guard let workspace = workspace(id: workspaceID) else { throw FactoryError.workspaceNotFound(workspaceID) }
        let controller = TerminalController.shared
        let routing = routing(workspaceID: workspaceID)
        switch destination {
        case .tab(_, let paneID, _):
            guard let requestedPane = UUID(uuidString: paneID) else { throw FactoryError.paneNotFound(paneID) }
            return try tab(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, requestedPane: requestedPane, focus: focus)
        case .workspace(_, .tab):
            return try tab(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, requestedPane: nil, focus: focus)
        case .split(_, let paneID, let direction):
            let anchor = try anchorSurface(paneID: paneID, in: workspace)
            return try split(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, direction: direction, anchor: anchor, focus: focus)
        case .workspace(_, .split):
            return try split(controller: controller, routing: routing, typeRaw: typeRaw, url: url, initialCommand: initialCommand, workingDirectory: workingDirectory, direction: .right, anchor: nil, focus: focus)
        }
    }

    private static func tab(
        controller: TerminalController,
        routing: ControlRoutingSelectors,
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        requestedPane: UUID?,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let resolution = controller.controlSurfaceCreate(
            routing: routing,
            inputs: ControlSurfaceCreateInputs(
                typeRaw: typeRaw,
                providerRaw: nil,
                rendererRaw: nil,
                urlRaw: url,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                tmuxStartCommand: nil,
                remotePTYSessionID: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                // Bonsplit appends a new tab to the pane; no pane drop in the app honors
                // the drop index, so it is not honored here either.
                requestedPaneID: requestedPane,
                requestedFocus: focus
            )
        )
        if case .created(_, let createdWorkspaceID, _, let surfaceID, _) = resolution {
            return (createdWorkspaceID, surfaceID)
        }
        throw FactoryError.creationFailed("\(resolution)")
    }

    private static func split(
        controller: TerminalController,
        routing: ControlRoutingSelectors,
        typeRaw: String,
        url: String?,
        initialCommand: String?,
        workingDirectory: String?,
        direction: SurfaceSplitDirection,
        anchor: UUID?,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let resolution = controller.controlSurfaceSplit(
            routing: routing,
            inputs: ControlSurfaceSplitInputs(
                directionRaw: direction.rawValue,
                typeRaw: typeRaw,
                urlRaw: url,
                requestedSourceSurfaceID: anchor,
                workingDirectory: workingDirectory,
                initialCommand: initialCommand,
                tmuxStartCommand: nil,
                remotePTYSessionID: nil,
                remoteContextRaw: nil,
                startupEnvironment: [:],
                clientUnsupportedRemoteTmuxOptions: [],
                requestedFocus: focus,
                initialDividerPosition: nil
            )
        )
        if case .created(_, let createdWorkspaceID, _, let surfaceID, _) = resolution {
            return (createdWorkspaceID, surfaceID)
        }
        throw FactoryError.creationFailed("\(resolution)")
    }
}

/// The local pages an optimistic browser pane shows while its endpoint resolves (and if
/// that fails). Pure: strings in, HTML out, every dynamic value escaped.
enum SurfaceBrowserPlaceholder {
    /// "Connecting to <label>…" on the desktop's dark background, so the pane reads as
    /// the desktop's own loading state rather than a blank tab.
    static func connecting(_ label: String) -> String {
        let title = String(
            format: String(localized: "cloudTree.pane.connecting", defaultValue: "Connecting to %@…"),
            label
        )
        return page(title: title, detail: nil, spinner: true)
    }

    /// "Couldn't open <label>" with the typed error and the way back.
    static func failed(_ label: String, error: String) -> String {
        let title = String(
            format: String(localized: "cloudTree.pane.failed", defaultValue: "Couldn’t open %@"),
            label
        )
        let hint = String(
            localized: "cloudTree.pane.retryHint",
            defaultValue: "Close this pane and open it again from the sidebar."
        )
        return page(title: title, detail: "\(error)\n\(hint)", spinner: false)
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    private static func page(title: String, detail: String?, spinner: Bool) -> String {
        let detailHTML = detail.map { text in
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "<p>\(escape(String($0)))</p>" }
                .joined()
        } ?? ""
        let spinnerHTML = spinner ? "<div class=\"spinner\" role=\"progressbar\"></div>" : ""
        // The spinner's stylesheet ships only with a spinner: the failed page
        // must carry no trace of one (the tests assert on the whole document).
        let spinnerCSS = spinner ? """

          .spinner { width: 22px; height: 22px; margin: 0 auto 14px; border-radius: 50%;
                     border: 2px solid rgba(216,222,233,0.25); border-top-color: #d8dee9;
                     animation: spin 0.9s linear infinite; }
          @keyframes spin { to { transform: rotate(360deg); } }
        """ : ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
          html, body { margin: 0; height: 100%; background: #1f2430; color: #d8dee9; }
          body { display: flex; align-items: center; justify-content: center;
                 font: 14px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
          main { text-align: center; max-width: 36em; padding: 0 1.5em; }
          h1 { font-size: 15px; font-weight: 500; margin: 0 0 0.6em; }
          p { margin: 0.3em 0; opacity: 0.8; word-break: break-word; }\(spinnerCSS)
        </style></head>
        <body><main>\(spinnerHTML)<h1>\(escape(title))</h1>\(detailHTML)</main></body></html>
        """
    }
}
