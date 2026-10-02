import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

struct CloudDaemonBuildTests {
    @Test("connected link status exposes its observed daemon build")
    func connectedStatusExposesObservedBuild() {
        let build = SurfaceDaemonBuild(commit: "abcdef0123456789", remoteProtocol: 4, version: "1.2.3")
        let connected = CloudMachineLink.Connected(
            socketPath: "/tmp/cmux.sock",
            session: "cmux",
            daemonBuild: build
        )
        let status = CloudMachineLinkManager.LinkStatus(
            state: .connected,
            error: nil,
            observedDaemonBuild: connected.daemonBuild
        )

        #expect(status.observedDaemonBuild == build)
        #expect(build.displayName == "1.2.3")
    }

    @Test("missing daemon build stays absent for legacy links")
    func missingBuildStaysNil() {
        let connected = CloudMachineLink.Connected(socketPath: "/tmp/cmux.sock", session: "cmux")
        let status = CloudMachineLinkManager.LinkStatus(state: .connected, error: nil)

        #expect(connected.daemonBuild == nil)
        #expect(status.observedDaemonBuild == nil)
    }

    @Test("daemon build display names cover commit and unknown fallbacks")
    func displayNameFallbacks() {
        #expect(SurfaceDaemonBuild(commit: "abcdef0123456789").displayName == "abcdef012345")
        #expect(SurfaceDaemonBuild().displayName == "unknown")
    }

    @Test("surface machine info round trips an observed daemon build")
    func machineInfoCodableRoundTrip() throws {
        let build = SurfaceDaemonBuild(commit: "abcdef0123456789", remoteProtocol: 4, version: "1.2.3")
        let info = SurfaceMachineInfo(
            id: .cloud("build-test"), name: "Build test", status: "running",
            hasDesktop: false, linkState: .connected, observedDaemonBuild: build
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(info)
        let decoded = try decoder.decode(SurfaceMachineInfo.self, from: data)
        #expect(decoded.observedDaemonBuild == build)

        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["observedDaemonBuild"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try decoder.decode(SurfaceMachineInfo.self, from: legacyData).observedDaemonBuild == nil)
    }
}
