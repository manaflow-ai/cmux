#if DEBUG || CMUX_BENCH_HOOKS
import Testing
@testable import CmuxNextBrowser

/// `debug.webui` names each Chromium helper from its argv: the kind's name and, for a tab renderer,
/// its `--renderer-client-id` (the id a page's frames report), for every kind.
@Suite struct ChromiumHelperKindNameTests {
    @Test func everyKindHasItsCensusNameAndOnlyARendererHasAClientID() {
        let rows: [(ChromiumHelperProcess.Kind, String, Int32?)] = [
            (.renderer(clientID: 12), "renderer", 12),
            (.extensionRenderer, "extension_renderer", nil),
            (.gpu, "gpu", nil),
            (.network, "network", nil),
            (.utility, "utility", nil),
            (.other, "other", nil),
        ]
        for (kind, name, clientID) in rows {
            #expect(kind.name == name)
            #expect(kind.rendererClientID == clientID)
        }
    }

    @Test func argvClassifiesToTheCensusRow() {
        let renderer = ChromiumHelperProcess.classify(["cmux Helper (Renderer)", "--type=renderer", "--renderer-client-id=7"])
        #expect(renderer?.name == "renderer")
        #expect(renderer?.rendererClientID == 7)

        let extensionRenderer = ChromiumHelperProcess.classify(
            ["cmux Helper (Renderer)", "--type=renderer", "--extension-process", "--renderer-client-id=8"])
        #expect(extensionRenderer?.name == "extension_renderer")
        #expect(extensionRenderer?.rendererClientID == nil)

        #expect(ChromiumHelperProcess.classify(["h", "--type=gpu-process"])?.name == "gpu")
        #expect(ChromiumHelperProcess.classify(["h", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"])?.name == "network")
        #expect(ChromiumHelperProcess.classify(["h", "--type=utility", "--utility-sub-type=storage.mojom.StorageService"])?.name == "utility")
        // A renderer without a client id is no tab renderer.
        #expect(ChromiumHelperProcess.classify(["h", "--type=renderer"])?.rendererClientID == nil)
        #expect(ChromiumHelperProcess.classify(["cmux"]) == nil)
    }
}
#endif
