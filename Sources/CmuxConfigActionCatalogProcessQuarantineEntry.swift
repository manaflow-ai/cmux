struct CmuxConfigActionCatalogProcessQuarantineEntry {
    let key: String
    let lane: CmuxConfigActionCatalogProcessQuarantineLane
    var owner: (any CmuxConfigActionCatalogQuarantinedProcess)?
}
