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

    @Test func aChangeWithNothingAskedShowsOnlyTheBody() {
        #expect(CloudChangeRequest().spec("Snapshot Cloud Machine").lines.count == 1)
    }
}
