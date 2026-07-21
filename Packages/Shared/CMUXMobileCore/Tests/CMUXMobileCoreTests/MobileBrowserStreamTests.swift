import Foundation
import Testing
@testable import CMUXMobileCore

@Suite
struct MobileBrowserStreamTests {
    @Test
    func wireDTOsRoundTripWithSnakeCaseKeys() throws {
        let dialog = MobileBrowserDialogEvent(
            panelID: "panel-1",
            dialogID: "dialog-1",
            kind: .httpBasicAuthentication,
            title: "Authentication Required",
            message: "example.com requires a username and password.",
            host: "example.com",
            buttons: [
                MobileBrowserDialogButton(id: "sign_in", label: "Sign In", role: .default),
                MobileBrowserDialogButton(id: "cancel", label: "Cancel", role: .cancel),
            ],
            textField: MobileBrowserDialogTextField(
                placeholder: "Password",
                initial: "octocat",
                secure: true
            ),
            informational: false
        )
        let descriptor = MobileBrowserPanelDescriptor(
            panelID: "panel-1",
            workspaceID: "workspace-1",
            url: "https://example.com",
            title: "Example",
            pageWidth: 640,
            pageHeight: 480,
            canGoBack: true,
            canGoForward: false,
            isLoading: true,
            pendingDialog: dialog
        )
        try expectRoundTrip(descriptor, expectedKeys: [
            "panel_id", "workspace_id", "url", "title", "page_width", "page_height",
            "can_go_back", "can_go_forward", "is_loading", "pending_dialog",
        ])

        try expectRoundTrip(
            MobileBrowserFrameEvent(
                panelID: "panel-1",
                sequence: 42,
                format: .jpeg,
                pageWidth: 640,
                pageHeight: 480,
                pixelWidth: 1280,
                pixelHeight: 960,
                dataBase64: "YWJj"
            ),
            expectedKeys: ["panel_id", "seq", "format", "page_width", "page_height", "pixel_width", "pixel_height", "data_b64"]
        )
        try expectRoundTrip(
            MobileBrowserStateEvent(
                panelID: "panel-1",
                url: nil,
                title: nil,
                canGoBack: false,
                canGoForward: true,
                isLoading: false,
                progress: 0.5,
                editableFocused: true
            ),
            expectedKeys: ["panel_id", "can_go_back", "can_go_forward", "is_loading", "progress", "editable_focused"]
        )
        try expectRoundTrip(MobileBrowserClosedEvent(panelID: "panel-1"), expectedKeys: ["panel_id"])
        try expectRoundTrip(
            MobileBrowserPointerInput(panelID: "panel-1", kind: .click, x: 12, y: 34, clickCount: 2, button: .left),
            expectedKeys: ["panel_id", "kind", "x", "y", "click_count", "button"]
        )
        try expectRoundTrip(
            MobileBrowserScrollInput(panelID: "panel-1", deltaX: 1, deltaY: -2, phase: .momentumChanged, x: 3, y: 4),
            expectedKeys: ["panel_id", "dx", "dy", "phase", "x", "y"]
        )
        try expectRoundTrip(
            MobileBrowserKeyInput(panelID: "panel-1", key: "return", modifiers: ["command"]),
            expectedKeys: ["panel_id", "key", "modifiers"]
        )
        try expectRoundTrip(MobileBrowserTextInput(panelID: "panel-1", text: "héllo"), expectedKeys: ["panel_id", "text"])
        let viewport = MobileBrowserViewport(width: 393, height: 852, scale: 3)
        try expectRoundTrip(
            MobileBrowserStreamStartParameters(panelID: "panel-1", viewport: viewport),
            expectedKeys: ["panel_id", "viewport_width", "viewport_height", "viewport_scale"]
        )
        try expectRoundTrip(
            MobileBrowserStreamStartParameters(panelID: "panel-1"),
            expectedKeys: ["panel_id"]
        )
        try expectRoundTrip(
            MobileBrowserViewportParameters(panelID: "panel-1", viewport: viewport),
            expectedKeys: ["panel_id", "viewport_width", "viewport_height", "viewport_scale"]
        )
        try expectRoundTrip(
            dialog,
            expectedKeys: [
                "panel_id", "dialog_id", "kind", "title", "message", "host",
                "buttons", "text_field", "informational",
            ]
        )
        try expectRoundTrip(
            MobileBrowserDialogRespondParameters(
                panelID: "panel-1",
                dialogID: "dialog-1",
                buttonID: "sign_in",
                text: "octocat\u{0}secret"
            ),
            expectedKeys: ["panel_id", "dialog_id", "button_id", "text"]
        )
        try expectRoundTrip(
            MobileBrowserDialogResolvedEvent(panelID: "panel-1", dialogID: "dialog-1"),
            expectedKeys: ["panel_id", "dialog_id"]
        )
        #expect(dialog.textField?.secure == true)
    }

    @Test
    func streamStartRejectsPartialViewportTriples() {
        let partial = Data(#"{"panel_id":"panel-1","viewport_width":393}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MobileBrowserStreamStartParameters.self, from: partial)
        }
    }

    @Test
    func dialogQueueClaimsExactlyOnceAndHandsPendingDialogToLateSubscriber() {
        let first = MobileBrowserDialogEvent(
            panelID: "panel-1",
            dialogID: "dialog-1",
            kind: .javaScriptConfirm,
            title: "This page says:",
            message: "Continue?",
            host: nil,
            buttons: [MobileBrowserDialogButton(id: "cancel", label: "Cancel", role: .cancel)],
            textField: nil,
            informational: false
        )
        let second = MobileBrowserDialogEvent(
            panelID: "panel-1",
            dialogID: "dialog-2",
            kind: .fileUpload,
            title: "Needs your Mac",
            message: nil,
            host: nil,
            buttons: [MobileBrowserDialogButton(id: "cancel", label: "Cancel", role: .cancel)],
            textField: nil,
            informational: true
        )
        var queue = MobileBrowserDialogQueue()
        let installedFirst = queue.install(first)
        let installedSecond = queue.install(second)
        #expect(installedFirst)
        #expect(installedSecond)
        #expect(queue.current == first)
        let firstClaim = queue.claim(dialogID: first.dialogID)
        let secondClaim = queue.claim(dialogID: first.dialogID)
        #expect(firstClaim == first)
        #expect(secondClaim == nil)
        #expect(queue.current == second)
    }

    @Test
    func dialogQueueClaimsAllPendingDialogsOnPanelClose() {
        var queue = MobileBrowserDialogQueue()
        for index in 1...2 {
            let installed = queue.install(MobileBrowserDialogEvent(
                panelID: "panel-1",
                dialogID: "dialog-\(index)",
                kind: .javaScriptAlert,
                title: nil,
                message: nil,
                host: nil,
                buttons: [MobileBrowserDialogButton(id: "ok", label: "OK", role: .default)],
                textField: nil,
                informational: false
            ))
            #expect(installed)
        }
        let claimed = queue.claimAll()
        let secondClaim = queue.claimAll()
        #expect(claimed.map(\.dialogID) == ["dialog-1", "dialog-2"])
        #expect(queue.current == nil)
        #expect(secondClaim.isEmpty)
    }

    @Test
    func unknownFrameFormatSurvivesDecodeAndReencode() throws {
        let data = Data(#"{"panel_id":"p","seq":1,"format":"avif","page_width":10,"page_height":20,"pixel_width":20,"pixel_height":40,"data_b64":"AA=="}"#.utf8)
        let decoded = try JSONDecoder().decode(MobileBrowserFrameEvent.self, from: data)
        #expect(decoded.format == .unknown("avif"))
        let roundTripped = try JSONDecoder().decode(
            MobileBrowserFrameEvent.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTripped.format == .unknown("avif"))
    }

    @Test
    func pacingCapsUnackedFramesAndCoalescesDirtyWork() {
        var pacing = MobileBrowserStreamPacing()
        pacing.noteDirty(at: 0)
        #expect(pacing.decision(at: 0) == .captureJPEG(dirtyGeneration: 1))
        #expect(pacing.recordEmission(format: .jpeg, observedDirtyGeneration: 1, at: 0) == 1)
        pacing.noteDirty(at: 0.010)
        #expect(pacing.decision(at: 0.010) == .wait(0.023))
        #expect(pacing.recordEmission(format: .jpeg, observedDirtyGeneration: 2, at: 0.033) == 2)
        pacing.noteDirty(at: 0.040)
        #expect(pacing.recordEmission(format: .jpeg, observedDirtyGeneration: 3, at: 0.066) == 3)
        pacing.noteDirty(at: 0.070)
        #expect(pacing.decision(at: 1) == .flowControlled)
        pacing.acknowledge(sequence: 2)
        #expect(pacing.unackedSequences == [3])
        #expect(pacing.decision(at: 1) == .captureJPEG(dirtyGeneration: 4))
    }

    @Test
    func pacingEmitsLosslessSettleFrameAfterQuietInterval() {
        var pacing = MobileBrowserStreamPacing()
        pacing.noteDirty(at: 10)
        _ = pacing.recordEmission(format: .jpeg, observedDirtyGeneration: 1, at: 10)
        guard case let .wait(remaining) = pacing.decision(at: 10.299) else {
            Issue.record("Expected settle deadline")
            return
        }
        #expect(abs(remaining - 0.001) < 0.000_001)
        #expect(pacing.decision(at: 10.300) == .capturePNG(dirtyGeneration: 1))
        _ = pacing.recordEmission(format: .png, observedDirtyGeneration: 1, at: 10.300)
        #expect(pacing.decision(at: 11) == .idle)
    }

    @Test
    func dirtySignalDuringCaptureIsNotClearedByOlderFrame() {
        var pacing = MobileBrowserStreamPacing()
        pacing.noteDirty(at: 0)
        pacing.noteDirty(at: 0.01)
        _ = pacing.recordEmission(format: .jpeg, observedDirtyGeneration: 1, at: 0.02)
        #expect(pacing.decision(at: 0.053) == .captureJPEG(dirtyGeneration: 2))
    }

    @Test
    func frameSizeBudgetAccountsForBase64AndChoosesDownscale() {
        let budget = MobileBrowserFrameSizeBudget(maximumBase64Bytes: 100)
        #expect(budget.contains(encodedByteCount: 75))
        #expect(!budget.contains(encodedByteCount: 76))
        let factor = budget.downscaleFactor(encodedByteCount: 300)
        #expect(factor < 1)
        #expect(factor >= 0.25)
    }

    private func expectRoundTrip<Value: Codable & Equatable>(
        _ value: Value,
        expectedKeys: Set<String>
    ) throws {
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == expectedKeys)
        #expect(try JSONDecoder().decode(Value.self, from: data) == value)
    }
}
