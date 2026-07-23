struct CmuxConfigActionCatalogProcessQuarantineState: Sendable, Equatable {
    let generalReservedCount: Int
    let generalQuarantinedCount: Int
    let globalReservedCount: Int
    let globalQuarantinedCount: Int
    let blockedKeys: Set<String>

    var reservedCount: Int { generalReservedCount + globalReservedCount }
    var quarantinedCount: Int { generalQuarantinedCount + globalQuarantinedCount }
}
