@testable import CmuxNextPopups
import Foundation
import Testing

/// Only a build whose Info.plist declares the sign-in capability installs
/// the system session handler (cx-q3y7).
@Suite struct WebAuthSessionHandlerTests {
    private let handler = WebAuthSessionHandler(broker: WebAuthSessionBroker(opener: FakeWebAuthOpener()))

    /// A bundle on disk with `info` as its Info.plist.
    private func bundle(_ info: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appending(path: "webauth-\(UUID().uuidString).bundle")
        let contents = root.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        return try #require(Bundle(url: root))
    }

    @Test func aBuildWithoutTheCapabilityInstallsNoHandler() throws {
        let plain = try bundle(["CFBundleIdentifier": "com.cmuxterm.tests.webauth.plain"])
        var installed: [WebAuthSessionHandler] = []
        #expect(!WebAuthSessionHandler.install(handler, bundle: plain) { installed.append($0) })
        #expect(installed.isEmpty)
    }

    @Test func aBuildThatDeclaresTheCapabilityInstallsItsHandler() throws {
        let capable = try bundle([
            "CFBundleIdentifier": "com.cmuxterm.tests.webauth.capable",
            WebAuthSessionHandler.capabilitiesKey: ["IsSupported": true, "EphemeralBrowserSessionIsSupported": true],
        ])
        var installed: [WebAuthSessionHandler] = []
        #expect(WebAuthSessionHandler.install(handler, bundle: capable) { installed.append($0) })
        #expect(installed.count == 1)
        #expect(installed.first === handler)
    }

    /// macOS calls the handler on its own queue, through the ObjC protocol's
    /// selectors. A main-actor handler's `@objc` witnesses check for the main
    /// actor and trap there; the handler must return (a nil request does
    /// nothing).
    @Test func macOSCanCallTheHandlerOffTheMainActor() async throws {
        let begin = "beginHandlingWebAuthenticationSessionRequest:"
        let cancel = "cancelWebAuthenticationSessionRequest:"
        try #require(handler.responds(to: NSSelectorFromString(begin)))
        try #require(handler.responds(to: NSSelectorFromString(cancel)))
        let system = handler
        await Task.detached {
            _ = system.perform(NSSelectorFromString(begin), with: nil)
            _ = system.perform(NSSelectorFromString(cancel), with: nil)
        }.value
    }
}
