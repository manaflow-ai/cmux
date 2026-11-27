import AppKit
import CmuxNextCloudUI
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// The sheet before an agent's or a script's Cloud machine change: it names the machine and shows what was
/// asked, so the person sees what they allow, and only Allow says yes.
@Suite struct CloudChangeRequestTests {
    @Test func theSheetNamesTheMachineAndWhatWasAsked() {
        let spec = CloudChangeRequest(machine: "paint", asked: ["size": "large", "disk": "100"]).spec("Resize Cloud Machine")
        #expect(spec.title == "Resize Cloud Machine")
        #expect(spec.identifier == CloudChangeRequest.identifier)
        #expect(Array(spec.lines.dropFirst()) == ["Machine: paint", "Disk: 100 GB", "Size: large"])
        #expect(spec.buttons.map(\.id).contains(CloudChangeRequest.accept))
    }

    /// A resize, snapshot or template runs without the sheet; its record names it, the machine and what was asked,
    /// a disk with its unit (Leo's toast read "disk: 128").
    @Test func anUnaskedChangesNoticeNamesTheMachineAndWhatWasAsked() {
        #expect(CloudChangeRequest(machine: "fsr-runner-proto", asked: ["size": "medium"]).notice("Resize Machine…")
            == "Resize Machine by an agent or a script: fsr-runner-proto, Size: medium")
        #expect(CloudChangeRequest(machine: "paint", asked: ["disk": "128"]).notice("Resize Machine…")
            == "Resize Machine by an agent or a script: paint, Disk: 128 GB")
    }

    /// An agent's resize of a lane's machine is recorded, never toasted over what the person is doing (Leo, 2026-11-27,
    /// on "Resize Machine by an agent or a script: lane-…, disk: 128": "also why are we showing this"). A gate that
    /// says toast still shows one: the toast stays for a change that needs the person.
    @MainActor @Test func aRoutineChangeIsRecordedNotToasted() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        defer { _ = CmuxToastCenter.shared.close(id: "cloud-change-cloudResizeMachine", in: window); window.closeAfterTest() }
        window.orderFront(nil)
        var records: [String] = []
        let request = CloudChangeRequest(machine: "paint", asked: ["disk": "128"])
        request.noticed("cloudResizeMachine", title: "Resize Machine…", toast: false, in: window) { records.append($0) }
        #expect(records == ["Resize Machine by an agent or a script: paint, Disk: 128 GB"])
        #expect(CmuxToastCenter.shared.toasts(in: window).isEmpty)
        request.noticed("cloudResizeMachine", title: "Resize Machine…", toast: true, in: window) { records.append($0) }
        #expect(CmuxToastCenter.shared.toasts(in: window).map(\.id) == ["cloud-change-cloudResizeMachine"])
    }

    @Test func aChangeWithNothingAskedShowsOnlyTheBody() {
        #expect(CloudChangeRequest().spec("Snapshot Cloud Machine").lines.count == 1)
    }
}
