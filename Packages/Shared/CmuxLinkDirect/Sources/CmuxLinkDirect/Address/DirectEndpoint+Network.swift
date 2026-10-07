import Network

extension DirectEndpoint {
    var nwEndpoint: NWEndpoint {
        switch target {
        case let .address(address, port):
            .hostPort(host: address.nwHost, port: NWEndpoint.Port(rawValue: port) ?? .any)
        case let .service(name, type, domain):
            .service(name: name, type: type, domain: domain, interface: nil)
        }
    }
}
