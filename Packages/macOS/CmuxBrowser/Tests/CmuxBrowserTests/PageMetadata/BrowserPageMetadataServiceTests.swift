import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser page metadata")
struct BrowserPageMetadataServiceTests {
    private let fixture = BrowserPageMetadataFixture()

    @Test("The transport dials the resolver-approved numeric address")
    func transportReceivesPinnedAddress() async throws {
        let address = BrowserPageMetadataResolvedAddress(
            family: .ipv4,
            bytes: [93, 184, 216, 34]
        )
        let transport = RecordingPageMetadataTransport(responses: [
            fixture.response(body: "<html><title>Example Title</title></html>"),
        ])
        let service = BrowserPageMetadataService(
            resolver: StubPageMetadataResolver(addressesByHost: ["example.com": [address]]),
            transport: transport
        )

        let title = try await service.title(
            for: #require(URL(string: "https://example.com/path?q=1"))
        )

        #expect(title == "Example Title")
        #expect(await transport.recordedHosts() == ["example.com"])
        #expect(await transport.recordedAddresses() == [address])
    }

    @Test("A private DNS answer fails closed before transport")
    func privateResolvedAddressIsRejected() async throws {
        let transport = RecordingPageMetadataTransport(responses: [])
        let service = BrowserPageMetadataService(
            resolver: StubPageMetadataResolver(addressesByHost: [
                "rebind.example": [BrowserPageMetadataResolvedAddress(
                    family: .ipv4,
                    bytes: [127, 0, 0, 1]
                )],
            ]),
            transport: transport
        )

        let title = try await service.title(
            for: #require(URL(string: "https://rebind.example/secret"))
        )

        #expect(title == nil)
        #expect(await transport.recordedAddresses().isEmpty)
    }

    @Test("Every redirect host is independently resolved and pinned")
    func redirectRevalidatesAndPinsNewHost() async throws {
        let firstAddress = BrowserPageMetadataResolvedAddress(
            family: .ipv4,
            bytes: [93, 184, 216, 34]
        )
        let redirectedAddress = BrowserPageMetadataResolvedAddress(
            family: .ipv4,
            bytes: [1, 1, 1, 1]
        )
        let transport = RecordingPageMetadataTransport(responses: [
            fixture.response(
                status: 302,
                headers: ["Location": "https://cdn.example.net/page"]
            ),
            fixture.response(body: "<title>Redirected</title>"),
        ])
        let service = BrowserPageMetadataService(
            resolver: StubPageMetadataResolver(addressesByHost: [
                "example.com": [firstAddress],
                "cdn.example.net": [redirectedAddress],
            ]),
            transport: transport
        )

        let title = try await service.title(
            for: #require(URL(string: "https://example.com/start"))
        )

        #expect(title == "Redirected")
        #expect(await transport.recordedHosts() == ["example.com", "cdn.example.net"])
        #expect(await transport.recordedAddresses() == [firstAddress, redirectedAddress])
    }

}
