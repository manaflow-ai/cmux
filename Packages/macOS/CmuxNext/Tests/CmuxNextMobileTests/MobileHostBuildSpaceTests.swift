import CMUXAuthCore
import Foundation
import Testing
@testable import CmuxNextMobile

/// hostd and the device list on the mobile service carry a tagged dev build's `X-Cmux-Build-Space`; nightly and
/// stable builds pass no variable and send no header.
@Suite struct MobileHostBuildSpaceTests {
    static let space = CMUXBuildSpace(devTag: "My_Tag 2")

    @Test("hostd gets CMUX_MOBILE_BUILD_SPACE only for a tagged dev build")
    func launchEnvironment() {
        var launch = MobileHostTests.launch(executable: URL(fileURLWithPath: "/bin/true"))
        #expect(launch.environment(inherited: [:])["CMUX_MOBILE_BUILD_SPACE"] == nil)
        launch.buildSpace = Self.space
        #expect(launch.environment(inherited: [:])["CMUX_MOBILE_BUILD_SPACE"] == "dev:my-tag-2")
        // An inherited value never leaks into the child.
        launch.buildSpace = nil
        #expect(launch.environment(inherited: ["CMUX_MOBILE_BUILD_SPACE": "dev:other"])["CMUX_MOBILE_BUILD_SPACE"] == nil)
    }

    @Test("The device directory's list and remove carry the header with a build space, none without", arguments: [true, false])
    func directory(tagged: Bool) async throws {
        let base = try #require(URL(string: "https://cmuxMobile.test"))
        let log = RequestLog()
        let space = try #require(Self.space)
        let directory = MobileHostDeviceDirectory(baseURL: base, buildSpace: tagged ? .dev(space) : .nightly) { request in
            await log.add(request)
            if request.httpMethod == "DELETE" { return (Data(), 200) }
            return (Data(#"{"devices":[{"deviceId":"a","kind":"phone","name":"P"}]}"#.utf8), 200)
        }
        let phones = try await directory.phones(token: "tok")
        try await directory.remove(try #require(phones.first), token: "tok")
        let requests = await log.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Cmux-Build-Space") == (tagged ? "dev:my-tag-2" : nil) })
    }

    @Test("A misconfigured dev build's device directory refuses before anything is sent")
    func directoryRefuses() async throws {
        let base = try #require(URL(string: "https://cmuxMobile.test"))
        let log = RequestLog()
        let directory = MobileHostDeviceDirectory(baseURL: base, buildSpace: .misconfiguredDev(reason: "it has no tag")) { request in
            await log.add(request)
            return (Data(#"{"devices":[]}"#.utf8), 200)
        }
        await #expect(throws: CMUXBuildSpaceError.self) { _ = try await directory.phones(token: "tok") }
        let phone = MobileHostKnownPhone.group([try #require(MobileHostRegisteredDevice(json: ["deviceId": "a", "kind": "phone", "name": "P"]))])
        await #expect(throws: CMUXBuildSpaceError.self) { try await directory.remove(try #require(phone.first), token: "tok") }
        #expect(await log.requests.isEmpty)
    }
}
