/// Every surface decision of one action: the descriptor's declaration of
/// where it can be invoked. The registry generates the palette list, the
/// right-click menus and the CLI verbs from it; all of them call the same
/// `ActionRegistry.perform` path with the caller's origin.
public nonisolated struct ActionSurfacePlan: Sendable, Hashable {
    public var palette: SurfaceDecision
    /// Offered: the CLI has the verb `cliName`. Exempt: only
    /// `cmux action run <id>` reaches it. Nil until declared (the parity
    /// test rejects that).
    public var cli: SurfaceDecision?
    /// The menus the action appears in. Empty requires
    /// `contextMenuExemption`.
    public var contextMenus: [ContextMenuPlacement]
    public var contextMenuExemption: SurfaceExemption?
    /// An MCP-only exemption on top of the CLI decision.
    public var mcpExemption: SurfaceExemption?

    public init(
        palette: SurfaceDecision = .offered,
        cli: SurfaceDecision? = nil,
        contextMenus: [ContextMenuPlacement] = [],
        contextMenuExemption: SurfaceExemption? = nil,
        mcpExemption: SurfaceExemption? = nil
    ) {
        self.palette = palette
        self.cli = cli
        self.contextMenus = contextMenus
        self.contextMenuExemption = contextMenuExemption
        self.mcpExemption = mcpExemption
    }

    /// The right-click decision: offered when placed, else the exemption.
    /// Nil when neither is declared (the parity test rejects that).
    public var contextMenu: SurfaceDecision? {
        if !contextMenus.isEmpty { return .offered }
        return contextMenuExemption.map(SurfaceDecision.exempt)
    }

    /// MCP follows the CLI: a tool exactly when the CLI has the verb and no
    /// MCP exemption applies.
    public var mcp: SurfaceDecision? {
        guard let cli, cli.isOffered else { return cli }
        return mcpExemption.map(SurfaceDecision.exempt) ?? .offered
    }

    /// The decision for `surface`, nil when undeclared.
    public func decision(for surface: ActionSurface) -> SurfaceDecision? {
        switch surface {
        case .palette: palette
        case .cli: cli
        case .contextMenu: contextMenu
        case .mcp: mcp
        }
    }
}
