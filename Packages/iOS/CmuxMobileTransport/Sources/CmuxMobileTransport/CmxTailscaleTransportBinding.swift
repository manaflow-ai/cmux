internal import CMUXMobileCore

struct CmxTailscaleTransportBinding: Sendable {
    let request: CmxByteTransportRequest
    let preparedRoute: CmxPreparedTailscaleRoute
    let authority: any CmxTailscaleRouteAuthorizing
}
