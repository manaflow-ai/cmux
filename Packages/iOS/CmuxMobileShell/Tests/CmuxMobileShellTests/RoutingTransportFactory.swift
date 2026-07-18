import CMUXMobileCore

struct RoutingTransportFactory: CmxByteTransportFactory {
    let router: RoutingHostRouter
}
