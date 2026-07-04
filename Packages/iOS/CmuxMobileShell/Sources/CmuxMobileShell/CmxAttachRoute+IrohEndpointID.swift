internal import CMUXMobileCore

extension CmxAttachRoute {
    var irohEndpointID: String? {
        guard kind == .iroh,
              case let .peer(id, _, _, _) = endpoint else {
            return nil
        }
        return id
    }
}
