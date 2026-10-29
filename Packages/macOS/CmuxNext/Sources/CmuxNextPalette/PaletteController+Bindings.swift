public import CmuxNextActions

extension PaletteController {
    // MARK: Registry wiring

    /// Binds the palette's own catalog actions: Command Palette (toggle),
    /// Go to Workspace (Cmd-P, what is open now), Search (Cmd-Shift-A, everything) and Search
    /// Keyboard Shortcuts. Go to Tab is Search Tabs, which the App binds (`tab.search`).
    public func bindRegistryActions() {
        Self.bindRegistryActions(on: registry, goToWorkspace: sources.workspaces != nil) { [weak self] in self }
    }

    /// Binds the palette's own catalog actions and the registry's argument
    /// collector to the palette `resolve` returns when each one runs. An App
    /// binds them before it builds its palette: the first
    /// palette key builds it in that key's turn, as Chrome's keyed services
    /// are made at their first `GetForProfile` (components/keyed_service/core/
    /// keyed_service_factory.cc).
    ///
    /// - Parameters:
    ///   - registry: The registry the palette runs on.
    ///   - goToWorkspace: Whether the palette has a workspace source (binds Go to Workspace).
    ///   - resolve: The palette, made at its first call; nil once it is gone.
    public static func bindRegistryActions(on registry: ActionRegistry, goToWorkspace: Bool,
                                           palette resolve: @escaping @MainActor () -> PaletteController?) {
        // Each one opens, toggles or selects in the input's turn: the whole change is local (`.done`).
        registry.bindEffect("commandPalette", effect: { _ in
            resolve()?.toggle(.commands)
            return .done
        })
        registry.bindEffect("palette.searchShortcuts", effect: { _ in
            resolve()?.show(.keyboardShortcuts)
            return .done
        })
        // Cmd-Shift-A: Search, which adds history and agent chats to the open items
        // (search-everything-DESIGN.md section 10.1). The id predates the change; user key files name it.
        registry.bindEffect("search.chats", effect: { invocation in
            _ = resolve()?.show(scope: PaletteScopeID.search, query: invocation["query"]?.stringValue ?? "")
            return .done
        })
        if goToWorkspace {
            // With a workspace (a palette row's typed ref, `palette.run`,
            // the CLI) it switches to it; without one it opens the page.
            registry.bindEffect("goToWorkspace", effect: { invocation in
                guard let palette = resolve() else { return .done }
                if let workspace = invocation["workspace"]?.targetValue?.id ?? invocation["workspace"]?.stringValue {
                    guard let source = palette.sources.workspaces else { return .done }
                    // An id that names no workspace is refused (`not_found` on the socket), never a silent success.
                    guard source.workspaces.contains(where: { $0.id == workspace }) else {
                        palette.registry.refuseNotFound(PaletteStrings.workspaceNotFound(workspace))
                        return .done
                    }
                    source.selectWorkspace(id: workspace)
                } else if !palette.show(scope: PaletteScopeID.workspaces) {
                    // Cmd-P lists only what is open: workspaces, then their groups, panes and tabs.
                    palette.show(.workspaces)
                }
                return .done
            })
        }
        registry.argumentCollector = { id, invocation in
            resolve()?.collectArguments(for: id, invocation: invocation)
        }
        registry.argumentAsker = { id, invocation, ask in
            resolve()?.collectArguments(for: id, invocation: invocation, asking: ask)
        }
    }
}
