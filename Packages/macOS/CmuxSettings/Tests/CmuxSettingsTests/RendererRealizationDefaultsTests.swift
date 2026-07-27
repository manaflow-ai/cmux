import Testing

@testable import CmuxSettings

@Suite("Renderer realization defaults")
struct RendererRealizationDefaultsTests {
    @Test("five tabs retain only one warm renderer")
    func fiveTabBaseline() {
        let terminal = SettingCatalog().terminal

        #expect(terminal.rendererRealizationIdleSeconds.defaultValue == 5)
        #expect(terminal.rendererRealizationMaxWarmRenderers.defaultValue == 1)
    }
}
