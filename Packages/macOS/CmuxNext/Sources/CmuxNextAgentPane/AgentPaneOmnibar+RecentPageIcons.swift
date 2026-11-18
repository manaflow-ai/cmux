#if DEBUG || CMUX_BENCH_HOOKS
extension AgentPaneOmnibar {
    /// The bar's recent pages as a bench reads them (`debug.new_tab state`, `omnibar_history`): each page's
    /// address and whether the page has an icon, in the bar's order.
    public var recentPageIcons: [(url: String, icon: Bool)] {
        []
    }
}
#endif
