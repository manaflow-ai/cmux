import Testing
@testable import CmuxNextBrowser

/// "when we open up google meet inside our browser, it works well" (Leo, 2026-11-22). A Chromium tab
/// left a page's camera and microphone request with Chromium's own bubble, which cmux never shows, so
/// getUserMedia() never resolved and a call joined with no camera or microphone. The shim now sends
/// those requests to the prompt bar (`kHostPermissions`, permission_prompt_policy.h); this is the
/// bar's question for each set of bits Chromium sends.
@Suite struct CEFMediaPermissionPromptTests {
    @Test func cameraAndMicrophoneTogetherAskOneQuestion() {
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.camera | CEFPermissionPrompts.microphone) == .cameraAndMicrophone)
    }

    @Test func cameraAloneAndMicrophoneAloneAskForThatDevice() {
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.camera) == .camera)
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.microphone) == .microphone)
    }

    /// A page that asks for pan-tilt-zoom constraints gets the camera question; PTZ comes with it.
    @Test func panTiltZoomRidesWithTheCamera() {
        let ptz = CEFPermissionPrompts.cameraPanTiltZoom
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.camera | ptz) == .camera)
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.camera | ptz | CEFPermissionPrompts.microphone) == .cameraAndMicrophone)
    }

    @Test func locationStillAsksForLocation() {
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.geolocation) == .location)
    }

    /// The shim keeps a mixed set with Chromium, so the host never sees one; if it did, it asks nothing.
    @Test func aSetTheBarDoesNotAskIsNotAsked() {
        #expect(CEFPermissionPrompts.kind(of: 0) == nil)
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.camera | 1 << 3) == nil)
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.geolocation | CEFPermissionPrompts.camera) == nil)
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.notifications | CEFPermissionPrompts.geolocation) == nil)
    }
}

/// "when we open up google meet inside our browser, it works well" (Leo, 2026-11-22). getDisplayMedia()
/// never resolved in a Chromium tab: its own screen picker is never shown. The shim now sends it to the
/// prompt bar as its own kind, `kPermissionDisplayCapture`.
@Suite struct CEFDisplayCapturePromptTests {
    @Test func aScreenShareAsksTheScreenShareQuestion() {
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.displayCapture) == .screenShare)
    }

    /// It is asked every time: no per-site setting stores or answers it.
    @Test func aScreenShareHasNoSiteSetting() {
        #expect(BrowserPermissionKind.screenShare.siteKinds.isEmpty)
    }

    @Test func screenShareDoesNotMixWithOtherKinds() {
        #expect(CEFPermissionPrompts.kind(of: CEFPermissionPrompts.displayCapture | CEFPermissionPrompts.camera) == nil)
    }
}
