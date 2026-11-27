import CmuxNextCloudUI
import CmuxNextDesign
import Testing

/// The sheet before an agent's or a script's Cloud machine change: it names the machine and shows what was
/// asked, so the person sees what they allow, and only Allow says yes.
@Suite struct CloudChangeRequestTests {
    @Test func theSheetNamesTheMachineAndWhatWasAsked() {
        let spec = CloudChangeRequest(machine: "paint", asked: ["size": "large", "disk": "100"]).spec("Resize Cloud Machine")
        #expect(spec.title == "Resize Cloud Machine")
        #expect(spec.identifier == CloudChangeRequest.identifier)
        #expect(Array(spec.lines.dropFirst()) == ["Machine: paint", "disk: 100", "size: large"])
        #expect(spec.buttons.map(\.id).contains(CloudChangeRequest.accept))
    }

    /// A resize, snapshot or template runs without the sheet; its log line after the fact (never a toast) names it, the machine and what was asked.
    @Test func anUnaskedChangesNoticeNamesTheMachineAndWhatWasAsked() {
        #expect(CloudChangeRequest(machine: "fsr-runner-proto", asked: ["size": "medium"]).notice("Resize Machine…")
            == "Resize Machine by an agent or a script: fsr-runner-proto, size: medium")
        #expect(CloudChangeRequest.unasked == ["cloudResizeMachine", "palette.cloud.snapshot", "palette.cloud.promoteTemplate"])
    }

    /// An unasked change gives a line for the activity log; one that asked first, none.
    @Test func onlyAnUnaskedChangeGivesALogLine() {
        let request = CloudChangeRequest(machine: "m", asked: ["size": "large"])
        #expect(request.noticed("cloudResizeMachine", title: "Resize Machine…") == "Resize Machine by an agent or a script: m, size: large")
        #expect(request.noticed("cloudRestoreMachine", title: "Restore") == nil)
    }

    @Test func aChangeWithNothingAskedShowsOnlyTheBody() {
        #expect(CloudChangeRequest().spec("Snapshot Cloud Machine").lines.count == 1)
    }
}
