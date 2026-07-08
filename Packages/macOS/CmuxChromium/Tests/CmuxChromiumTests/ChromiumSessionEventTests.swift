import COwlFreshRuntime
import Testing
@testable import CmuxChromium

struct ChromiumSessionEventTests {
    @Test func mapsReadyEvent() {
        var cEvent = OwlFreshMojoEvent()
        cEvent.kind = kOwlFreshMojoEventReady
        cEvent.host_pid = 4242
        cEvent.context_id = 7
        #expect(ChromiumSessionEvent(cEvent: cEvent) == .ready(hostPID: 4242, compositorContextID: 7))
    }

    @Test func mapsNavigationEventCopyingStrings() {
        "https://example.com".withCString { url in
            "Example".withCString { title in
                var cEvent = OwlFreshMojoEvent()
                cEvent.kind = kOwlFreshMojoEventNavigation
                cEvent.url = url
                cEvent.title = title
                cEvent.loading = true
                let event = ChromiumSessionEvent(cEvent: cEvent)
                #expect(event == .navigationChanged(url: "https://example.com", title: "Example", isLoading: true))
            }
        }
    }

    @Test func mapsDisconnectedEvent() {
        var cEvent = OwlFreshMojoEvent()
        cEvent.kind = kOwlFreshMojoEventDisconnected
        #expect(ChromiumSessionEvent(cEvent: cEvent) == .disconnected)
    }

    @Test func navigationToleratesNullStrings() {
        var cEvent = OwlFreshMojoEvent()
        cEvent.kind = kOwlFreshMojoEventNavigation
        cEvent.loading = false
        #expect(ChromiumSessionEvent(cEvent: cEvent) == .navigationChanged(url: "", title: "", isLoading: false))
    }

    @Test func modelFoldsEvents() async {
        await MainActor.run {
            let model = ChromiumBrowserModel()
            model.apply(.ready(hostPID: 99, compositorContextID: 3))
            #expect(model.hostProcessID == 99)
            #expect(model.compositorContextID == 3)
            model.apply(.compositorChanged(contextID: 0))
            #expect(model.compositorContextID == 3)
            model.apply(.navigationChanged(url: "https://a.dev", title: "A", isLoading: true))
            #expect(model.currentURL == "https://a.dev")
            #expect(model.pageTitle == "A")
            #expect(model.isLoading)
            model.apply(.disconnected)
            #expect(model.isDisconnected)
            #expect(!model.isLoading)
        }
    }
}
