/// Read ordering prevents a delayed background sample replacing a newer drag.
struct ExternalWindowSample: Sendable {
    let startedAt: UInt64
    let snapshot: ExternalApplicationWindowSnapshot?
}
