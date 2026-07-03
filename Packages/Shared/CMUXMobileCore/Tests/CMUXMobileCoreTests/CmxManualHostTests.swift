import Testing
@testable import CMUXMobileCore

@Test func attachRouteAcceptsManualHostPortEndpoint() throws {
    let route = try CmxAttachRoute(
        id: "manual_host",
        kind: .manualHost,
        endpoint: .hostPort(host: "192.168.4.12", port: 58_465)
    )

    #expect(route.kind == .manualHost)
    #expect(route.endpoint == .hostPort(host: "192.168.4.12", port: 58_465))
}

@Test func manualHostNormalizerRejectsURLsAndAcceptsBracketedIPv6() {
    #expect(CmxManualHost(" studio-mac.corp.example ")?.rawValue == "studio-mac.corp.example")
    #expect(CmxManualHost("[fd00::12]")?.rawValue == "fd00::12")
    #expect(CmxManualHost("https://studio-mac.corp.example") == nil)
    #expect(CmxManualHost("studio-mac.corp.example/path") == nil)
    #expect(CmxManualHost("studio!mac.local") == nil)
    #expect(CmxManualHost("my:host") == nil)
    #expect(CmxManualHost("fd00::12") == nil)
    #expect(CmxManualHost("[my:host]") == nil)
    #expect(CmxManualHost("[studio-mac.local]") == nil)
    #expect(CmxManualHost("[abc]def]") == nil)
    #expect(CmxManualHost("studio]mac") == nil)
    #expect(CmxManualHost("studio mac") == nil)
}
