import Testing
@testable import CmuxBrowser

@Suite("Chromium permission policy")
struct BrowserChromiumPermissionPolicyTests {
    private let policy = BrowserChromiumPermissionPolicy()

    @Test func requestBitsMatchCEFPermissionTypes() {
        // cef_permission_request_types_t
        #expect(BrowserChromiumPermissionRequest.camera.rawValue == 1 << 2)
        #expect(BrowserChromiumPermissionRequest.clipboard.rawValue == 1 << 4)
        #expect(BrowserChromiumPermissionRequest.geolocation.rawValue == 1 << 8)
        #expect(BrowserChromiumPermissionRequest.microphone.rawValue == 1 << 12)
        #expect(BrowserChromiumPermissionRequest.notifications.rawValue == 1 << 15)
    }

    @Test func mediaAccessMapsDeviceCaptureToCameraAndMicrophone() {
        #expect(BrowserChromiumPermissionRequest(mediaAccess: 1) == .microphone)
        #expect(BrowserChromiumPermissionRequest(mediaAccess: 2) == .camera)
        #expect(BrowserChromiumPermissionRequest(mediaAccess: 3) == [.camera, .microphone])
        #expect(BrowserChromiumPermissionRequest(mediaAccess: 8) == .screenCapture)
        #expect(BrowserChromiumPermissionRequest(mediaAccess: 0).isEmpty)
    }

    @Test func cameraAndMicrophoneAskInOnePromptLikeWebKit() {
        #expect(policy.decide(.camera, sessionGrants: nil) == .prompt([.camera]))
        #expect(policy.decide([.camera, .microphone], sessionGrants: nil) == .prompt([.camera, .microphone]))
        #expect(policy.decide(.clipboard, sessionGrants: nil) == .prompt([.clipboardRead]))
    }

    @Test(arguments: [
        BrowserChromiumPermissionRequest.geolocation,
        .notifications,
        .midiSysex,
        .screenCapture,
        .windowManagement,
        .localNetworkAccess,
        [],
    ])
    func everyOtherKindIsDeniedWithoutAsking(_ request: BrowserChromiumPermissionRequest) {
        #expect(policy.decide(request, sessionGrants: nil) == .deny)
    }

    @Test func aGroupWithAnUnaskableKindDeniesTheWholeRequest() {
        #expect(policy.decide([.camera, .geolocation], sessionGrants: nil) == .deny)
        #expect(policy.decide([.microphone, .screenCapture], sessionGrants: nil) == .deny)
    }

    @Test func sessionTabsAnswerFromGrantsWithoutAsking() {
        let grants: Set<String> = ["camera", "geolocation"]
        #expect(policy.decide(.camera, sessionGrants: grants) == .accept)
        #expect(policy.decide(.geolocation, sessionGrants: grants) == .accept)
        #expect(policy.decide([.camera, .microphone], sessionGrants: grants) == .deny)
        #expect(policy.decide(.notifications, sessionGrants: grants) == .deny)
        // Kinds a session cannot grant (WebKit supports the same four) are denied.
        #expect(policy.decide(.clipboard, sessionGrants: ["camera", "microphone", "geolocation", "notifications"]) == .deny)
        #expect(policy.decide(.camera, sessionGrants: []) == .deny)
    }

    @Test func shimResultsNeverDismiss() {
        #expect(BrowserChromiumPermissionPolicy.immediateShimResult(for: .accept) == .accept)
        #expect(BrowserChromiumPermissionPolicy.immediateShimResult(for: .deny) == .deny)
        #expect(BrowserChromiumPermissionPolicy.immediateShimResult(for: .prompt([.camera])) == nil)
        #expect(BrowserChromiumPermissionPolicy.shimResult(forPromptAnswer: true).rawValue == 1)
        #expect(BrowserChromiumPermissionPolicy.shimResult(forPromptAnswer: false).rawValue == 2)
        #expect(BrowserChromiumPermissionPolicy.shimResult(forPromptAnswer: nil).rawValue == 0)
    }
}
