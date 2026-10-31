import Foundation
@testable import CmuxNextMobileHost
import Testing

/// hostd serves phones the app's own Chief (cmux-next-ios full verify D2): a DEV or tagged build keeps its
/// Chief at `~/.cmux/chief/<bundle id>`, so the launch must name that owner instead of letting hostd
/// guess `~/.cmux/chief/default`.
@MainActor
struct IPhoneHostChiefTests {
    static func dependencies(chief: IPhoneHostService.ChiefPlacement?) -> IPhoneHostService.Dependencies {
        IPhoneHostService.Dependencies(
            executable: URL(fileURLWithPath: "/bin/cmux-mobile-host"), baseURL: URL(fileURLWithPath: "/dev/null"),
            stackProjectID: "p", stateDirectory: URL(fileURLWithPath: "/tmp/cmux-mobile-state"),
            accessToken: { _ in "t" }, daemonSocket: { "/tmp/cmux-tui-501/cmux-app-tag.sock" }, acpmux: { nil },
            fileRoots: { ["/a"] }, computerName: { "Mac" }, chief: { chief })
    }

    static let account = IPhoneHostService.Account(userID: "u", teamID: "personal-u", teamName: nil, email: nil)

    @Test func theLaunchNamesTheAppsOwnChief() async throws {
        let placement = IPhoneHostService.ChiefPlacement(session: "cmux-chief-1a2b3c4d",
                                                         socket: "/tmp/cmux-tui-501/cmux-chief-1a2b3c4d.sock")
        let dependencies = Self.dependencies(chief: placement)
        let launch = IPhoneHostService.launch(dependencies, executable: URL(fileURLWithPath: "/bin/cmux-mobile-host"),
                                              account: Self.account, deviceID: "d", deviceName: "Mac",
                                              daemonSocket: "/tmp/cmux-tui-501/cmux-app-tag.sock",
                                              chief: await dependencies.chief?())
        let environment = launch.environment(inherited: [:])
        #expect(environment["CMUX_MOBILE_CHIEF_SESSION"] == "cmux-chief-1a2b3c4d")
        #expect(environment["CMUX_MOBILE_CHIEF_SOCKET"] == "/tmp/cmux-tui-501/cmux-chief-1a2b3c4d.sock")
        #expect(environment["CMUX_MOBILE_TEAM_ID"] == "personal-u")
    }

    @Test func aChiefNotConnectedYetStillNamesItsSession() async throws {
        let dependencies = Self.dependencies(chief: .init(session: "cmux-chief-1a2b3c4d", socket: nil))
        let launch = IPhoneHostService.launch(dependencies, executable: URL(fileURLWithPath: "/bin/cmux-mobile-host"),
                                              account: Self.account, deviceID: "d", deviceName: "Mac",
                                              daemonSocket: "/tmp/cmux-tui-501/cmux-app-tag.sock",
                                              chief: await dependencies.chief?())
        let environment = launch.environment(inherited: [:])
        #expect(environment["CMUX_MOBILE_CHIEF_SESSION"] == "cmux-chief-1a2b3c4d")
        #expect(environment["CMUX_MOBILE_CHIEF_SOCKET"] == nil)
    }
}
