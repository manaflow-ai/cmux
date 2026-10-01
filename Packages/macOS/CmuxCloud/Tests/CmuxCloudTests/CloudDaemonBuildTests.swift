import CmuxCloud
import CmuxSurfaceCatalogModel
import Testing

struct CloudDaemonBuildTests {
    @Test("live daemon build identity is retained by link status")
    func linkStatusRetainsObservedBuild() {
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
}
