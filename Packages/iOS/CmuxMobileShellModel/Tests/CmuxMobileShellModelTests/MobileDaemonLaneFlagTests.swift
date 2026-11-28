import Foundation
import Testing
@testable import CmuxMobileShellModel

struct MobileDaemonLaneFlagTests {
    private func defaults(_ value: Bool?) -> UserDefaults {
        let store = UserDefaults(suiteName: "daemon-lane-\(UUID().uuidString)")!
        if let value { store.set(value, forKey: MobileDaemonLaneFlag.defaultsKey) }
        return store
    }

    @Test func offByDefault() {
        #expect(!MobileDaemonLaneFlag(buildType: .dev, environment: [:], defaults: defaults(nil)).isEnabled)
    }

    @Test func devAndBetaOptInThroughEnvOrDefaults() {
        #expect(MobileDaemonLaneFlag(buildType: .dev, environment: ["CMUX_DAEMON_LANE": "1"], defaults: defaults(nil)).isEnabled)
        #expect(MobileDaemonLaneFlag(buildType: .beta, environment: [:], defaults: defaults(true)).isEnabled)
        #expect(!MobileDaemonLaneFlag(buildType: .internal, environment: ["CMUX_DAEMON_LANE": "0"], defaults: defaults(true)).isEnabled)
    }

    @Test func neverInAppStoreOrDemoBuilds() {
        for build in [MobileBuildType.prod, .demo] {
            #expect(!MobileDaemonLaneFlag(buildType: build, environment: ["CMUX_DAEMON_LANE": "1"], defaults: defaults(true)).isEnabled)
        }
    }

    @Test func requiresTheMacCapability() {
        let flag = MobileDaemonLaneFlag(buildType: .dev, environment: ["CMUX_DAEMON_LANE": "1"], defaults: defaults(nil))
        #expect(flag.isAvailable(hostCapabilities: ["daemon_lane.v1", "events.v1"]))
        #expect(!flag.isAvailable(hostCapabilities: ["events.v1"]))
    }
}
