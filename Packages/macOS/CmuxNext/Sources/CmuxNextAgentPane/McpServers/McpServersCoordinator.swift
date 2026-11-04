public import AppKit
public import CmuxNextActions
public import CmuxNextControl
public import CmuxNextDesign
import SwiftUI

/// Owns Settings > MCP Servers (plans/cmux-next/mcp-connect-DESIGN.md row 3c): one
/// ``McpServersModel`` shared by the page's tabs, the palette's MCP Servers action and the
/// `cmux mcp` control methods. Each request goes to this app's acpmux on a short person-proven line
/// (``AcpmuxMcpServersService``). The palette and `cmux mcp auth|key|policy|approve-tools NAME`
/// only open the page and select a connection: the person clicks every change, and Remove asks
/// first in a cmux dialog.
///
/// The app makes one, conforms to ``McpServersHost`` with one-line forwards and shows the page
/// through its internal page tabs:
///
/// ```swift
/// private(set) lazy var mcpServers = McpServersCoordinator(host: self, dialogs: .shared)
/// ```
public final class McpServersCoordinator {
    /// The page's internal page id (`local-page:mcp-servers:<uuid>` tabs).
    public static let pageID = "mcp-servers"

    /// The service the page and `cmux mcp` share: one short person line per request.
    public let service: any McpServersServing
    private weak var host: (any McpServersHost)?
    private let dialogs: CmuxDialogCenter
    private var sharedModel: McpServersModel?

    /// - Parameters:
    ///   - host: The app (weak: the app owns this coordinator).
    ///   - dialogs: Shows Remove's confirmation.
    ///   - service: acpmux's person methods; nil uses ``AcpmuxMcpServersService`` on the host's
    ///     acpmux (tests pass a fake).
    public init(host: any McpServersHost, dialogs: CmuxDialogCenter, service: (any McpServersServing)? = nil) {
        self.host = host
        self.dialogs = dialogs
        self.service = service ?? AcpmuxMcpServersService { [weak host] in
            guard let environment = host?.mcpServersEnvironment else { return nil }
            return await AcpmuxPersonLine.open(environment)
        }
    }

    /// The tab title ("MCP Servers", localized).
    public var pageTitle: String { McpServersView.paneTitle }
    /// The tab's SF Symbol.
    public var pageSymbol: String { "puzzlepiece.extension" }
    /// The open model, nil before the first show and after the last tab closed.
    public var model: McpServersModel? { sharedModel }

    /// Shows the page in the active window, else opens it, with the connection `reference` names
    /// (its name or id) selected. Changes nothing in acpmux. `focus` false (automation) opens the
    /// tab without selecting it.
    /// - Returns: False when no window can show it.
    @discardableResult
    public func show(connection reference: String?, focus: Bool) -> Bool {
        guard let host else { return false }
        let model = makeModel()
        model.focus(reference)
        guard host.mcpServersShowPage(focus: focus) else { return false }
        // task-owner: one read of the list per show; the model outlives it while a tab shows it
        Task { await model.reload() }
        return true
    }

    /// A new view for one page tab, over the shared model.
    public func makePageView() -> NSView {
        let model = makeModel()
        let view = NSHostingView(rootView: McpServersView(model: model, confirmRemove: { _, _ in }))
        view.rootView = McpServersView(model: model, confirmRemove: { [weak self, weak view] connection, remove in
            guard let self, let view else { return }
            self.confirmRemove(connection, in: view, remove: remove)
        })
        view.setAccessibilityIdentifier("cmux.mcpServers.page")
        return view
    }

    /// A page tab closed: the model goes once no window shows the page.
    public func pageClosed() {
        guard host?.mcpServersPageIsOpen() != true else { return }
        sharedModel = nil
    }

    /// Binds the palette's MCP Servers (`mcpServers.show`): a user run selects the tab, automation
    /// opens it without changing focus.
    public func bind(into registry: ActionRegistry) {
        registry.bindEffect("mcpServers.show", effect: { [weak self] invocation in
            guard let self, self.show(connection: nil, focus: invocation.allowsViewChange) else {
                return .refused(McpServersStrings.noWindow)
            }
            return .done
        })
    }

    /// The control methods behind `cmux mcp` (``McpServersControl``).
    public func controlMethods() -> [ControlMethod] {
        McpServersControl(coordinator: self).methods()
    }

    private func makeModel() -> McpServersModel {
        if let sharedModel { return sharedModel }
        let model = McpServersModel(service: service, openURL: { [weak self] url in
            self?.host?.mcpServersOpenBrowserTab(url)
        })
        sharedModel = model
        return model
    }

    /// Asks in a cmux dialog on the page's tab whether to remove `connection`; `remove` runs only
    /// on Remove.
    private func confirmRemove(_ connection: McpServerConnection, in view: NSView, remove: @escaping @MainActor () -> Void) {
        let buttons = [CmuxDialogButton.cancel(McpServersStrings.cancel),
                       CmuxDialogButton(id: "remove", title: McpServersStrings.remove, role: .destructive)]
        let spec = CmuxDialogSpec(title: McpServersStrings.removeConfirm,
                                  lines: [connection.title.isEmpty ? connection.name : connection.title],
                                  buttons: buttons, identifier: "cmux.mcpServers.removeConfirm",
                                  layout: CmuxDialogSpec.Layout(alertFor: buttons))
        dialogs.present(spec, in: .tab(view)) { answer in
            if answer.button == "remove" { remove() }
        }
    }
}
