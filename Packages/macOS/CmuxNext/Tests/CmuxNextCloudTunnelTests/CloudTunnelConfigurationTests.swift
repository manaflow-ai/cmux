@testable import CmuxNextCloudTunnel
import Foundation
import NetworkExtension
import Testing

/// The completed config the server and app produce, read the way the packet tunnel uses it.
@Suite struct CloudTunnelConfigurationTests {
    static let server = """
        [Interface]
        PrivateKey = cHJpdmF0ZS1rZXktYnl0ZXMtMzItbG9uZy1hYWFhYWE=
        Address = 10.192.0.7/32, fd00:c0::7/128
        MTU = 1380

        [Peer]
        PublicKey = cHVibGljLWtleS1ieXRlcy0zMi1sb25nLWFhYWFhYWE=
        AllowedIPs = 10.192.0.0/20, 10.16.4.0/24, fd00:c0::/64
        Endpoint = gw.freestyle.example:51820 # gateway
        PersistentKeepalive = 25
        """

    @Test func readsAddressesRoutesMTUAndEndpoint() throws {
        let configuration = try CloudTunnelConfiguration(wgQuick: Self.server)
        #expect(configuration.addresses.map(\.description) == ["10.192.0.7/32", "fd00:c0::7/128"])
        #expect(configuration.routes.map(\.description) == ["10.192.0.0/20", "10.16.4.0/24", "fd00:c0::/64"])
        #expect(configuration.mtu == 1380)
        #expect(configuration.endpointHost == "gw.freestyle.example")
    }

    @Test func itsDescriptionNeverHoldsThePrivateKey() throws {
        let configuration = try CloudTunnelConfiguration(wgQuick: Self.server)
        #expect(!configuration.description.contains("cHJpdmF0ZS1rZXk"))
        #expect(!String(reflecting: configuration.addresses).contains("cHJpdmF0ZS1rZXk"))
    }

    @Test(arguments: [
        ("[Interface]\nAddress = 10.0.0.2/32\n[Peer]\nAllowedIPs = 10.0.0.0/24\nEndpoint = h:1", CloudTunnelConfiguration.ParseError.missingPrivateKey),
        ("[Interface]\nPrivateKey = \n[Peer]\nAllowedIPs = 10.0.0.0/24\nEndpoint = h:1", .missingPrivateKey),
        ("[Interface]\nPrivateKey = k\n[Peer]\nAllowedIPs = 10.0.0.0/24\nEndpoint = h:1", .missingAddress),
        ("[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n[Peer]\nEndpoint = h:1", .missingRoutes),
        ("[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/32\n[Peer]\nAllowedIPs = 10.0.0.0/24", .missingEndpoint),
        ("[Interface]\nPrivateKey = k\nAddress = 10.0.0.2/33\n[Peer]\nAllowedIPs = 10.0.0.0/24\nEndpoint = h:1", .invalid("10.0.0.2/33")),
    ])
    func refusesAConfigTheTunnelCannotUse(text: String, expected: CloudTunnelConfiguration.ParseError) {
        #expect(throws: expected) { try CloudTunnelConfiguration(wgQuick: text) }
    }

    @Test(arguments: ["0.0.0.0/0", "0.0.0.0/1", "128.0.0.0/1", "8.8.8.0/24", "192.168.1.0/24", "10.0.0.0/7", "172.32.0.0/16", "::/0", "fd00::/8", "2001:db8::/64"])
    func refusesARouteOutsideTheCloudNetworks(route: String) {
        let text = Self.server.replacingOccurrences(of: "AllowedIPs = 10.192.0.0/20", with: "AllowedIPs = \(route), 10.192.0.0/20")
        #expect(throws: CloudTunnelConfiguration.ParseError.self) { try CloudTunnelConfiguration(wgQuick: text) }
    }

    @Test(arguments: ["10.192.0.0/20", "10.0.0.0/12", "100.64.3.0/24", "172.20.0.0/16", "fd12:3456::/48"])
    func acceptsACloudNetworkRoute(route: String) throws {
        #expect(try CloudTunnelCIDR(parsing: route).isCloudRoute)
    }

    @Test func anIPv6EndpointKeepsItsHost() {
        #expect(CloudTunnelConfiguration.host(ofEndpoint: "[2001:db8::1]:51820") == "2001:db8::1")
        #expect(CloudTunnelConfiguration.host(ofEndpoint: "198.51.100.4:51820") == "198.51.100.4")
        #expect(CloudTunnelConfiguration.host(ofEndpoint: "nohost") == nil)
    }

    @Test func networkSettingsRouteOnlyTheCloudNetworksNeverTheDefaultRoute() throws {
        let settings = try CloudTunnelConfiguration(wgQuick: Self.server).networkSettings()
        #expect(settings.tunnelRemoteAddress == "gw.freestyle.example")
        #expect(settings.mtu == 1380)
        let ipv4 = try #require(settings.ipv4Settings)
        #expect(ipv4.addresses == ["10.192.0.7"])
        #expect(ipv4.subnetMasks == ["255.255.255.255"])
        let routes = (ipv4.includedRoutes ?? []).map { "\($0.destinationAddress)/\($0.destinationSubnetMask)" }
        #expect(routes == ["10.192.0.0/255.255.240.0", "10.16.4.0/255.255.255.0"])
        let ipv6 = try #require(settings.ipv6Settings)
        #expect((ipv6.includedRoutes ?? []).map(\.destinationAddress) == ["fd00:c0::"])
        #expect(settings.dnsSettings == nil, "the tunnel never changes the Mac's DNS")
    }

    @Test func providerConfigurationRoundTripsAndRefusesAnotherSchema() {
        let saved = CloudTunnelProviderConfiguration(wgQuick: Self.server).dictionary
        #expect(CloudTunnelProviderConfiguration(dictionary: saved)?.wgQuick == Self.server)
        var future = saved
        future["schemaVersion"] = 2
        #expect(CloudTunnelProviderConfiguration(dictionary: future) == nil)
        #expect(CloudTunnelProviderConfiguration(dictionary: nil) == nil)
    }
}
