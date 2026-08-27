import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Chromium navigation interception")
@MainActor
struct ChromiumNavigationInterceptionTests {
    @Test("Blocked top-level document requests are failed before commit")
    func blockedTopLevelRequest() async throws {
        let transport = PolicyCDPTransport()
        let connection = ChromiumCDPConnection(transport: transport)
        try await connection.connect()
        let interceptor = ChromiumNavigationInterceptor(policyHandler: { request in
            #expect(request.request.url?.scheme == "http")
            return .cancel
        })
        try await interceptor.install(connection: connection)

        let handled = try await interceptor.handle(
            CDPEvent(
                method: "Fetch.requestPaused",
                params: .object([
                    "requestId": .string("request-1"),
                    "frameId": .string("main-frame"),
                    "resourceType": .string("Document"),
                    "request": .object([
                        "url": .string("http://insecure.example/"),
                        "method": .string("GET"),
                        "headers": .object([:]),
                    ]),
                ])
            ),
            connection: connection
        )

        #expect(handled)
        let commands = await transport.commands()
        #expect(commands.contains { command in
            command["method"] == .string("Fetch.failRequest") &&
                command["params"]?["requestId"] == .string("request-1")
        })
        await connection.shutdown()
    }
}
