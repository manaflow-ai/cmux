import Foundation

/// Why a completed Cloud scan produced no listeners usable by the authenticated browser proxy.
public enum CloudPortDiscoveryEmptyReason: String, Codable, Hashable, Sendable {
    case noListeningService = "no_listening_service"
    case otherInterfaceOnly = "other_interface_only"
}
