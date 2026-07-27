internal import CMUXMobileCore
import Darwin
import Foundation
@preconcurrency import Network

enum CmxTailscaleRouteProofError: Error, Equatable, Sendable {
    case unsupportedRouteKind
    case unsupportedAuthorizationMode
    case authorizationEvidenceMismatch
    case unsupportedEndpoint
    case nonNumericPeer
    case peerOutsideTailscaleRange
    case peerIsLocalDevice
    case pathUnavailable
    case tailscaleInterfaceUnavailable
    case ambiguousTailscaleInterfaces
    case routeGenerationChanged
    case interfaceChanged
    case connectionPathUnavailable
    case localEndpointMismatch
    case remoteEndpointMismatch
    case remotePortMismatch
}

struct CmxTailscaleIPAddress: Hashable, Sendable {
    enum Family: Sendable {
        case ipv4
        case ipv6
    }

    let family: Family
    let bytes: Data

    init?(_ rawHost: String) {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 {
            host = String(trimmed.dropFirst().dropLast())
        } else {
            host = trimmed
        }

        if let address = IPv4Address(host) {
            family = .ipv4
            bytes = address.rawValue
        } else if let address = IPv6Address(host) {
            family = .ipv6
            bytes = address.rawValue
        } else {
            return nil
        }
    }

    init?(family: Family, bytes: Data) {
        switch family {
        case .ipv4:
            guard bytes.count == MemoryLayout<in_addr>.size else { return nil }
        case .ipv6:
            guard bytes.count == MemoryLayout<in6_addr>.size else { return nil }
        }
        self.family = family
        self.bytes = bytes
    }

    var nwHost: NWEndpoint.Host {
        switch family {
        case .ipv4:
            return .ipv4(IPv4Address(bytes)!)
        case .ipv6:
            return .ipv6(IPv6Address(bytes)!)
        }
    }

    var isTailscaleAddress: Bool {
        let octets = [UInt8](bytes)
        switch family {
        case .ipv4:
            return octets.count == 4 && octets[0] == 100 && (octets[1] & 0xC0) == 64
        case .ipv6:
            return octets.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
        }
    }

    var isTailscalePeerAddress: Bool {
        guard isTailscaleAddress else { return false }
        guard family == .ipv4 else { return true }
        let octets = [UInt8](bytes)
        // Tailscale reserves these service ranges. They cannot identify a peer
        // Mac and may terminate locally, so a bearer route must never target them.
        if octets[0] == 100, octets[1] == 100,
           octets[2] == 0 || octets[2] == 100 {
            return false
        }
        if octets[0] == 100, octets[1] == 115,
           octets[2] == 92 || octets[2] == 93 {
            return false
        }
        return true
    }
}

struct CmxNetworkInterfaceIdentity: Hashable, Sendable {
    let name: String
    let index: Int
}

struct CmxTailscaleInterfaceSnapshot: Equatable, Sendable {
    let identity: CmxNetworkInterfaceIdentity
    let isUp: Bool
    let isRunning: Bool
    let addresses: Set<CmxTailscaleIPAddress>

    var tailnetAddresses: Set<CmxTailscaleIPAddress> {
        Set(addresses.filter(\.isTailscaleAddress))
    }
}

struct CmxTailscaleAuthoritySnapshot: Equatable, Sendable {
    let generation: UInt64
    let pathSatisfied: Bool
    let availableInterfaces: Set<CmxNetworkInterfaceIdentity>
    let systemInterfaces: [CmxTailscaleInterfaceSnapshot]
}

struct CmxTailscaleConnectionPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    let availableInterfaces: Set<CmxNetworkInterfaceIdentity>
    let localAddress: CmxTailscaleIPAddress?
    let remoteAddress: CmxTailscaleIPAddress?
    let remotePort: Int?
}

struct CmxTailscaleRouteProof: Equatable, Sendable {
    let request: CmxByteTransportRequest
    let peerAddress: CmxTailscaleIPAddress
    let peerPort: Int
    let interface: CmxNetworkInterfaceIdentity
    let selfAddresses: Set<CmxTailscaleIPAddress>
    let generation: UInt64
}

struct CmxTailscaleRouteProofValidator {
    func prepare(
        request: CmxByteTransportRequest,
        snapshot: CmxTailscaleAuthoritySnapshot
    ) throws -> CmxTailscaleRouteProof {
        guard request.route.kind == .tailscale else {
            throw CmxTailscaleRouteProofError.unsupportedRouteKind
        }
        guard case let .legacyTailscaleBearer(evidence) = request.authorizationMode else {
            throw CmxTailscaleRouteProofError.unsupportedAuthorizationMode
        }
        guard case let .hostPort(host, port) = request.route.endpoint else {
            throw CmxTailscaleRouteProofError.unsupportedEndpoint
        }
        guard evidence.authorizes(
            macDeviceID: request.expectedPeerDeviceID,
            host: host,
            port: port
        ) else {
            throw CmxTailscaleRouteProofError.authorizationEvidenceMismatch
        }
        guard let peerAddress = CmxTailscaleIPAddress(host) else {
            throw CmxTailscaleRouteProofError.nonNumericPeer
        }
        guard peerAddress.isTailscalePeerAddress else {
            throw CmxTailscaleRouteProofError.peerOutsideTailscaleRange
        }
        guard snapshot.pathSatisfied else {
            throw CmxTailscaleRouteProofError.pathUnavailable
        }

        let candidates = tailscaleInterfaceCandidates(in: snapshot)
        guard !candidates.isEmpty else {
            throw CmxTailscaleRouteProofError.tailscaleInterfaceUnavailable
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw CmxTailscaleRouteProofError.ambiguousTailscaleInterfaces
        }
        guard !candidate.tailnetAddresses.contains(peerAddress) else {
            throw CmxTailscaleRouteProofError.peerIsLocalDevice
        }

        return CmxTailscaleRouteProof(
            request: request,
            peerAddress: peerAddress,
            peerPort: port,
            interface: candidate.identity,
            selfAddresses: candidate.tailnetAddresses,
            generation: snapshot.generation
        )
    }

    func validate(
        proof: CmxTailscaleRouteProof,
        authoritySnapshot: CmxTailscaleAuthoritySnapshot,
        connectionPath: CmxTailscaleConnectionPathSnapshot
    ) throws {
        guard authoritySnapshot.generation == proof.generation else {
            throw CmxTailscaleRouteProofError.routeGenerationChanged
        }
        guard authoritySnapshot.pathSatisfied else {
            throw CmxTailscaleRouteProofError.pathUnavailable
        }
        let candidates = tailscaleInterfaceCandidates(in: authoritySnapshot)
        guard candidates.count == 1,
              let candidate = candidates.first,
              candidate.identity == proof.interface,
              candidate.tailnetAddresses == proof.selfAddresses else {
            throw CmxTailscaleRouteProofError.interfaceChanged
        }
        guard connectionPath.isSatisfied,
              connectionPath.availableInterfaces.contains(proof.interface) else {
            throw CmxTailscaleRouteProofError.connectionPathUnavailable
        }
        guard let localAddress = connectionPath.localAddress,
              proof.selfAddresses.contains(localAddress) else {
            throw CmxTailscaleRouteProofError.localEndpointMismatch
        }
        guard connectionPath.remoteAddress == proof.peerAddress else {
            throw CmxTailscaleRouteProofError.remoteEndpointMismatch
        }
        guard connectionPath.remotePort == proof.peerPort else {
            throw CmxTailscaleRouteProofError.remotePortMismatch
        }
    }

    private func tailscaleInterfaceCandidates(
        in snapshot: CmxTailscaleAuthoritySnapshot
    ) -> [CmxTailscaleInterfaceSnapshot] {
        snapshot.systemInterfaces.filter { interface in
            interface.identity.name.hasPrefix("utun") &&
                interface.identity.index > 0 &&
                interface.isUp &&
                interface.isRunning &&
                snapshot.availableInterfaces.contains(interface.identity) &&
                !interface.tailnetAddresses.isEmpty
        }
    }
}
