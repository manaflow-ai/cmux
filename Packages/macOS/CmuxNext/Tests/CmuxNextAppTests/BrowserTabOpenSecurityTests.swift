import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor
struct BrowserTabOpenSecurityTests {
    @Test func aCloudBrowserProxyWithoutCredentialsIsRefused() throws {
        let args: JSONValue = .object([
            "engine": .string("cef"),
            "url": .string("http://localhost:3000/"),
            "incarnation": .number(11),
            "generation": .number(7),
            "machineStore": .object([
                "machine": .string("vm-alpha01"),
                "machineName": .string("alpha"),
                "proxy": .object([
                    "kind": .string("http"),
                    "host": .string("127.0.0.1"),
                    "port": .number(19_999),
                ]),
            ]),
        ])

        #expect(throws: BrowserTabOpen.Refusal.proxyInvalid) {
            try BrowserTabOpen.request(args: args, page: BrowserTabOpen.callerPage)
        }
    }

    @Test func anAuthenticatedCloudBrowserRouteIsAcceptedForTheAppProxy() throws {
        let args: JSONValue = .object([
            "engine": .string("cef"),
            "url": .string("http://localhost:3000/"),
            "incarnation": .number(11),
            "generation": .number(7),
            "machineStore": .object([
                "machine": .string("vm-alpha01"),
                "machineName": .string("alpha"),
                "proxy": .object([
                    "kind": .string("http"),
                    "host": .string("127.0.0.1"),
                    "port": .number(19_999),
                    "username": .string("cmux"),
                    "password": .string(String(repeating: "a", count: 64)),
                ]),
            ]),
        ])

        let request = try BrowserTabOpen.request(args: args, page: BrowserTabOpen.callerPage)
        #expect(request.machine == "vm-alpha01")
        #expect(request.incarnation == 11)
        #expect(request.generation == 7)
        #expect(request.proxyPort == 19_999)
        #expect(request.credential.username == "cmux")
        #expect(request.credential.password.utf8.count == 64)
    }
}
