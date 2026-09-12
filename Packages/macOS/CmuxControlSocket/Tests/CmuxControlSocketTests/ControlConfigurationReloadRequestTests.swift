import Testing
@testable import CmuxControlSocket

@Suite("Configuration reload intent")
struct ControlConfigurationReloadRequestTests {
    @Test
    func explicitQueueSelectionIsDistinctFromOrdinaryReloads() throws {
        let ordinary = try #require(ControlConfigurationReloadRequest(arguments: " \n"))
        let selection = try #require(ControlConfigurationReloadRequest(arguments: " --restart-video-background "))
        #expect(!ordinary.restartVideoBackground)
        #expect(selection.restartVideoBackground)
        #expect(ControlConfigurationReloadRequest(arguments: "--unknown") == nil)
        #expect(ControlConfigurationReloadRequest(arguments: "--restart-video-background extra") == nil)
    }
}
