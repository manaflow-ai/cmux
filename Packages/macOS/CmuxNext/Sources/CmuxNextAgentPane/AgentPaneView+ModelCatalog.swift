public import CmuxNextSettings

extension AgentPaneView {
    /// Pushes a changed model catalog to the page (`models.catalog` host event, CONTRACT section 2).
    /// The old script host gets nothing: its page asks for the catalog with `models.catalog` when
    /// the picker opens.
    public func pushModelCatalog(_ value: JSONValue) {
        deliver([.modelCatalog(value)], scripts: [])
    }
}
