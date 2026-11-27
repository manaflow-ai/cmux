/// One lifecycle-tokened panel port snapshot queued for MainActor publication.
struct PanelPortScanPublication: Sendable, Equatable {
    let key: PortScanner.PanelKey
    let ports: [Int]
    let revision: UInt64
}
