import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation

/// Joins the two identities one Mac app instance is known by.
///
/// Presence, the device registry and the pairing store name an instance by its
/// host device id (`MobileHostIdentity`). The v2 team directory names the same
/// instance by its own installation id, and that is the identity the iroh
/// transport authorizes and the host proves in its status reply. The two id
/// spaces share no value, but both publish the instance's iroh endpoint: the
/// host advertises it in its attach routes, and the directory lists it on the
/// device record. A host-keyed instance that advertises a directory Mac's
/// endpoint under the same tag is therefore that Mac, and its facts belong on
/// the directory-keyed row instead of forming a second one.
struct DeviceDirectoryIdentityIndex: Sendable {
    private struct Key: Hashable, Sendable {
        let endpoint: CmxIrohPeerIdentity
        let tag: String
    }

    private let directoryInstances: [Key: SurfaceDeviceInstanceID]

    /// - Parameters:
    ///   - authenticatedMacs: The Macs the current v2 directory authorizes.
    ///   - previous: The last merge's rows. A row the directory named keeps
    ///     collecting its host-keyed facts while the directory is briefly stale.
    init(authenticatedMacs: [DeviceDiscoveredMac], previous: [DeviceDirectoryRecord]) {
        var instances: [Key: SurfaceDeviceInstanceID] = [:]
        for record in previous {
            guard let endpoint = record.directoryEndpoint else { continue }
            instances[Key(endpoint: endpoint, tag: record.instance.tag)] = record.instance
        }
        // The live directory is authoritative over a remembered row.
        for mac in authenticatedMacs {
            let instance = SurfaceDeviceInstanceID(deviceID: mac.deviceID, tag: mac.tag)
            instances[Key(endpoint: mac.endpointID, tag: instance.tag)] = instance
        }
        directoryInstances = instances
    }

    /// The row a host-keyed instance belongs to: the directory instance that
    /// owns one of the iroh endpoints it advertises, otherwise the instance itself.
    func rowInstance(
        for instance: SurfaceDeviceInstanceID,
        advertising routes: [CmxAttachRoute]
    ) -> SurfaceDeviceInstanceID {
        for route in routes where route.kind == .iroh {
            guard case .peer(let endpoint, _) = route.endpoint,
                  let directory = directoryInstances[Key(endpoint: endpoint, tag: instance.tag)] else { continue }
            return directory
        }
        return instance
    }
}
