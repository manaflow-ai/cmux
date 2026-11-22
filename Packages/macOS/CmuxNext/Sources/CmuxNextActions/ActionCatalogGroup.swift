/// One domain's slice of the action catalog (window, tab, browser, ...).
/// Each group owns its descriptor rows and the argument helpers only it
/// uses; `ActionCatalog.groups` lists the groups in inventory order.
nonisolated protocol ActionCatalogGroup {
    /// The group's descriptors, in inventory order.
    static func descriptors() -> [ActionDescriptor]
}
