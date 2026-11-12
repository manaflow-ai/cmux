import AppKit
import Foundation
import Testing
@testable import CmuxComputerUse

@MainActor
struct ComputerUseHelperLaunchConfigurationTests {
    @Test(arguments: ComputerUseDaemonProfile.allCases)
    func backgroundLaunchDoesNotWaitForUserToDismissErrors(
        profile: ComputerUseDaemonProfile
    ) throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let launch = try makeLaunch(fixture: fixture, profile: profile)
        let configuration = try #require(launch.workspaceConfiguration(helperURL: fixture.bundle))

        #expect(!configuration.promptsUserIfNeeded)
        #expect(!configuration.activates)
        #expect(configuration.createsNewApplicationInstance)
        #expect(configuration.arguments == launch.arguments)
        #expect(configuration.environment == launch.environment)
    }

    @Test func nonExecutableHelperIsRejectedUntilPermissionsAreRepaired() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let launch = try makeLaunch(fixture: fixture)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fixture.executable.path
        )

        #expect(launch.workspaceConfiguration(helperURL: fixture.bundle) == nil)
        #expect(!FileManager.default.isExecutableFile(atPath: fixture.executable.path))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fixture.executable.path
        )
        #expect(launch.workspaceConfiguration(helperURL: fixture.bundle) != nil)
    }

    @Test func missingExecutableAndDirectoryAreRejected() throws {
        let fixture = try HelperBundleFixture()
        defer { fixture.remove() }
        let launch = try makeLaunch(fixture: fixture)
        try FileManager.default.removeItem(at: fixture.executable)
        #expect(launch.workspaceConfiguration(helperURL: fixture.bundle) == nil)

        try FileManager.default.createDirectory(
            at: fixture.executable, withIntermediateDirectories: false
        )
        #expect(launch.workspaceConfiguration(helperURL: fixture.bundle) == nil)
    }

    private func makeLaunch(
        fixture: HelperBundleFixture,
        profile: ComputerUseDaemonProfile = .native
    ) throws -> ComputerUseHelperLaunchConfiguration {
        try #require(ComputerUseHelperLaunchConfiguration(
            paths: ComputerUseRuntimePaths(
                homeDirectoryURL: fixture.root,
                socketRootDirectoryURL: fixture.root,
                environment: [:],
                bundleIdentifier: "com.cmuxterm.tests.helper-launch",
                authenticationToken: "test-token",
                hostAuthenticationToken: "test-host-token"
            ),
            profile: profile
        ))
    }
}
