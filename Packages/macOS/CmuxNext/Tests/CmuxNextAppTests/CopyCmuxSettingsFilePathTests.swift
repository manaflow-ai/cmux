import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextSettings
import Testing

/// Copy cmux-next.json Path (palette.copyCmuxSettingsFilePath) puts the path of the file the
/// app reads on the clipboard: the one Open cmux-next.json opens.
@MainActor struct CopyCmuxSettingsFilePathTests {
    @Test func copiesTheConfigFilePath() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let registry = services.registry
        registry.seed([ActionDescriptor(id: "palette.copyCmuxSettingsFilePath", title: "Copy cmux-next.json Path", category: .settings)])
        var copied: [String] = []
        registry.copyText = { copied.append($0) }
        let context = AppActionContext(services: services)
        SettingsHandlers.bind(into: registry, context: context)

        #expect(registry.perform("palette.copyCmuxSettingsFilePath", invocation: .init(origin: .user)))
        let expected = SettingsHandlers.cmuxConfigURL(context).path
        #expect(copied == [expected])
        #expect(expected.hasSuffix("cmux-next.json"))
    }
}
