import CmuxNextActions
import CmuxNextPalette

/// `palette.open {scope?, query?}`: opens a palette scope above the root
/// (plans/cmux-next/palette-scopes.md section 5). A keyboard or menu run
/// opens it; a CLI or MCP run only with `focus: true`, because the palette
/// takes the keyboard. Agents read rows with `palette.query` instead.
enum PaletteScopeHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("palette.open", run: { invocation in
            guard invocation.allowsViewChange else { throw ActionFailure(message: PaletteOpenRefusal.needsFocus.message) }
            let query = invocation["query"]?.stringValue ?? ""
            let window = context.activeWindow?.window
            guard let scope = invocation["scope"]?.stringValue, !scope.isEmpty, scope != PaletteScopeID.root.rawValue else {
                services.palette.show(.commands, relativeTo: window)
                if !query.isEmpty { services.palette.model.query = query }
                return
            }
            // Search opens from the sidebar's Search button when that window shows it, from a click,
            // the palette, a shortcut or the CLI alike (plans/cmux-next/sidebar-search.md).
            let anchor = scope == PaletteScopeID.search.rawValue ? context.services.windows.active?.sidebar.container.sidebarView.searchAnchor : nil
            guard services.palette.show(scope: PaletteScopeID(scope), query: query, relativeTo: window, anchoredTo: anchor) else {
                throw ActionFailure(message: PaletteOpenRefusal.unknownScope(scope).message)
            }
        })
    }
}
