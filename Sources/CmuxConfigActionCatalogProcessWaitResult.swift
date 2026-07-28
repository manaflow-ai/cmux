import Darwin

struct CmuxConfigActionCatalogProcessWaitResult: Sendable, Equatable {
    let processIdentifier: pid_t
    let status: Int32
    let errorNumber: Int32
}
