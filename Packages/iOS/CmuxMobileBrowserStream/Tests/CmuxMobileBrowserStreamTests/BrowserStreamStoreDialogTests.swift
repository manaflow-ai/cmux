import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileBrowserStream

@MainActor
struct BrowserStreamStoreDialogTests {
    @Test
    func payloadInstallsObservableDialogAndResponseClaimsIt() throws {
        let store = discoveredStore()
        let dialog = testDialog(dialogID: "dialog-1")

        store.receiveBrowserDialogPayload(try JSONEncoder().encode(dialog))
        #expect(store.state(for: dialog.panelID)?.pendingDialog == dialog)

        let claimed = store.beginBrowserDialogResponse(
            panelID: dialog.panelID,
            dialogID: dialog.dialogID
        )
        #expect(claimed == dialog)
        #expect(store.state(for: dialog.panelID)?.pendingDialog == nil)
        #expect(store.beginBrowserDialogResponse(panelID: dialog.panelID, dialogID: dialog.dialogID) == nil)
    }

    @Test
    func resolutionEventIsIdempotentAndTransportFailureCanRestore() throws {
        let store = discoveredStore()
        let dialog = testDialog(dialogID: "dialog-2")
        store.receiveBrowserDialogPayload(try JSONEncoder().encode(dialog))
        let claimed = try #require(store.beginBrowserDialogResponse(
            panelID: dialog.panelID,
            dialogID: dialog.dialogID
        ))
        store.restoreBrowserDialog(claimed)
        #expect(store.state(for: dialog.panelID)?.pendingDialog == dialog)

        let resolved = MobileBrowserDialogResolvedEvent(
            panelID: dialog.panelID,
            dialogID: dialog.dialogID
        )
        let payload = try JSONEncoder().encode(resolved)
        store.receiveBrowserDialogResolvedPayload(payload)
        store.receiveBrowserDialogResolvedPayload(payload)
        #expect(store.state(for: dialog.panelID)?.pendingDialog == nil)

        store.restoreBrowserDialog(claimed)
        #expect(store.state(for: dialog.panelID)?.pendingDialog == nil)
        store.receiveBrowserDialogPayload(try JSONEncoder().encode(dialog))
        #expect(store.state(for: dialog.panelID)?.pendingDialog == nil)
    }

    @Test
    func startDescriptorInstallsPendingDialogForLateAttach() {
        let dialog = testDialog(dialogID: "dialog-late")
        let store = BrowserStreamStore()
        store.browserStreamDidStart(descriptor(pendingDialog: dialog))
        #expect(store.state(for: dialog.panelID)?.pendingDialog == dialog)
    }

    private func discoveredStore() -> BrowserStreamStore {
        let store = BrowserStreamStore()
        store.replacePanels(in: "workspace-1", with: [descriptor(pendingDialog: nil)])
        return store
    }

    private func descriptor(pendingDialog: MobileBrowserDialogEvent?) -> MobileBrowserPanelDescriptor {
        MobileBrowserPanelDescriptor(
            panelID: "panel-1",
            workspaceID: "workspace-1",
            url: "https://example.com",
            title: "Example",
            pageWidth: 390,
            pageHeight: 844,
            canGoBack: false,
            canGoForward: false,
            isLoading: false,
            pendingDialog: pendingDialog
        )
    }

    private func testDialog(dialogID: String) -> MobileBrowserDialogEvent {
        MobileBrowserDialogEvent(
            panelID: "panel-1",
            dialogID: dialogID,
            kind: .javaScriptPrompt,
            title: "This page says:",
            message: "Name?",
            host: "example.com",
            buttons: [
                MobileBrowserDialogButton(id: "ok", label: "OK", role: .default),
                MobileBrowserDialogButton(id: "cancel", label: "Cancel", role: .cancel),
            ],
            textField: MobileBrowserDialogTextField(placeholder: nil, initial: "", secure: false),
            informational: false
        )
    }
}
