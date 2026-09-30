import Testing
@testable import CmuxNextBrowser

/// Chromium helper kinds from argv: a tab renderer carries the client id
/// its frames name; GPU, network, utility and extension renderers are shared.
@Suite struct ChromiumHelperProcessTests {
    private let helper = "/App/cmux DEV Helper (Renderer).app/Contents/MacOS/cmux DEV Helper (Renderer)"

    @Test func tabRendererCarriesItsClientID() {
        #expect(ChromiumHelperProcess.classify([helper, "--type=renderer", "--lang=en-US", "--renderer-client-id=67"])
            == .renderer(clientID: 67))
    }

    @Test func extensionRendererIsShared() {
        #expect(ChromiumHelperProcess.classify([helper, "--type=renderer", "--extension-process", "--renderer-client-id=69"])
            == .extensionRenderer)
    }

    @Test func gpuNetworkAndUtility() {
        #expect(ChromiumHelperProcess.classify(["h", "--type=gpu-process"]) == .gpu)
        #expect(ChromiumHelperProcess.classify(["h", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]) == .network)
        #expect(ChromiumHelperProcess.classify(["h", "--type=utility", "--utility-sub-type=storage.mojom.StorageService"]) == .utility)
    }

    @Test func theAppItselfIsNotAHelper() {
        #expect(ChromiumHelperProcess.classify(["/App/cmux DEV"]) == nil)
    }
}
