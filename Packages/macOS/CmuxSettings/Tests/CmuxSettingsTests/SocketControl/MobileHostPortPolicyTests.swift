import Foundation
import Testing

@testable import CmuxSettings

@Suite struct MobileHostPortPolicyTests {
    #if DEBUG
    @Test func taggedDebugDefaultUsesStablePerTagPortWhenUnset() throws {
        let suiteName = "MobileHostPortPolicyTests.Tagged.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalogDefault = SettingCatalog().mobile.iOSPairingPort.defaultValue
        let nodivsEnvironment = [SocketControlSettings.launchTagEnvKey: "nodivs"]
        let wtodoEnvironment = [SocketControlSettings.launchTagEnvKey: "wtodo"]
        let policy = MobileHostPortPolicy()

        let nodivs = policy.configuredPort(
            defaults: defaults,
            environment: nodivsEnvironment
        )
        let nodivsRelaunch = policy.configuredPort(
            defaults: defaults,
            environment: nodivsEnvironment
        )
        let wtodo = policy.configuredPort(
            defaults: defaults,
            environment: wtodoEnvironment
        )

        #expect(nodivs == nodivsRelaunch)
        #expect(nodivs != catalogDefault)
        #expect(wtodo != catalogDefault)
        #expect(nodivs != wtodo)
        #expect(MobileHostPortPolicy.taggedDevelopmentPortRange.contains(nodivs))
        #expect(MobileHostPortPolicy.taggedDevelopmentPortRange.contains(wtodo))
        #expect(policy.resolvedDesiredPort(
            defaults: defaults,
            environment: wtodoEnvironment
        ) == wtodo)
    }
    #endif

    @Test func validOverrideWinsOverTaggedDefault() throws {
        let suiteName = "MobileHostPortPolicyTests.Override.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(9000, forKey: SettingCatalog().mobile.iOSPairingPort.userDefaultsKey)
        let environment = [SocketControlSettings.launchTagEnvKey: "nodivs"]
        let policy = MobileHostPortPolicy()

        #expect(policy.configuredPort(
            defaults: defaults,
            environment: environment
        ) == 9000)
        #expect(policy.resolvedDesiredPort(
            defaults: defaults,
            environment: environment
        ) == 9000)
    }
}
