import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Page permission policy")
struct BrowserPagePermissionPolicyTests {
    private let policy = BrowserPagePermissionPolicy()

    private func request(_ kinds: [BrowserPagePermissionRequest.Kind], origin: URL? = URL(string: "https://meet.example.com")) -> BrowserPagePermissionRequest {
        BrowserPagePermissionRequest(kinds: kinds, origin: origin)
    }

    @Test func cameraMicrophoneAndClipboardAskLikeWebKit() {
        #expect(policy.decide(request([.camera]), sessionGrants: nil) == .ask([.camera]))
        #expect(policy.decide(request([.camera, .microphone]), sessionGrants: nil) == .ask([.camera, .microphone]))
        #expect(policy.decide(request([.clipboardRead]), sessionGrants: nil) == .ask([.clipboardRead]))
        #expect(policy.decide(request([.microphone, .microphone]), sessionGrants: nil) == .ask([.microphone]))
    }

    @Test(arguments: [
        BrowserPagePermissionRequest.Kind.geolocation,
        .notifications,
        .screenCapture,
        .midiSysex,
        .other("window-management"),
    ])
    func everyOtherKindIsDeniedWithoutAsking(_ kind: BrowserPagePermissionRequest.Kind) {
        #expect(policy.decide(request([kind]), sessionGrants: nil) == .deny)
    }

    @Test func emptyMixedOrOriginlessRequestsAreDenied() {
        #expect(policy.decide(request([]), sessionGrants: nil) == .deny)
        #expect(policy.decide(request([.camera, .geolocation]), sessionGrants: nil) == .deny)
        #expect(policy.decide(request([.camera], origin: nil), sessionGrants: nil) == .deny)
        #expect(policy.decide(request([.camera], origin: URL(string: "data:text/html,x")), sessionGrants: nil) == .deny)
    }

    @Test func sessionTabsAnswerFromGrantsWithoutAsking() {
        let grants: Set<String> = ["camera", "geolocation"]
        #expect(policy.decide(request([.camera]), sessionGrants: grants) == .grant)
        #expect(policy.decide(request([.geolocation]), sessionGrants: grants) == .grant)
        #expect(policy.decide(request([.camera, .microphone]), sessionGrants: grants) == .deny)
        #expect(policy.decide(request([.notifications]), sessionGrants: grants) == .deny)
        let all: Set<String> = ["camera", "microphone", "geolocation", "notifications"]
        #expect(policy.decide(request([.clipboardRead]), sessionGrants: all) == .deny)
        #expect(policy.decide(request([.camera]), sessionGrants: []) == .deny)
    }

    @Test func askableKindsAreConfigurable() {
        let wider = BrowserPagePermissionPolicy(askableKinds: [.camera, .microphone, .clipboardRead, .geolocation])
        #expect(wider.decide(request([.geolocation]), sessionGrants: nil) == .ask([.geolocation]))
    }
}

@Suite("Chromium permission request bits")
struct BrowserChromiumPermissionRequestTests {
    @Test func bitsMatchCEFPermissionTypes() {
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

    @Test func pageKindsAreOrderedAndUnknownBitsNamed() {
        let request: BrowserChromiumPermissionRequest = [.microphone, .camera, .windowManagement]
        #expect(request.pageKinds == [.camera, .microphone, .other("window-management")])
        #expect(BrowserChromiumPermissionRequest(rawValue: 1 << 30).pageKinds == [.other("permission-bit-30")])
        let page = BrowserChromiumPermissionRequest.clipboard.pageRequest(origin: URL(string: "https://a.example"))
        #expect(page.kinds == [.clipboardRead])
        #expect(page.origin == URL(string: "https://a.example"))
    }

    @Test func chromiumRequestsFlowThroughThePolicy() {
        let policy = BrowserPagePermissionPolicy()
        let origin = URL(string: "https://meet.example.com")
        #expect(policy.decide(BrowserChromiumPermissionRequest([.camera, .microphone]).pageRequest(origin: origin), sessionGrants: nil)
            == .ask([.camera, .microphone]))
        #expect(policy.decide(BrowserChromiumPermissionRequest.geolocation.pageRequest(origin: origin), sessionGrants: nil) == .deny)
        #expect(policy.decide(BrowserChromiumPermissionRequest.windowManagement.pageRequest(origin: origin), sessionGrants: nil) == .deny)
    }
}
