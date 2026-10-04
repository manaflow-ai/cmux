import CmuxRemoteSession
import Testing

struct RemoteTmuxPaneTitleMetadataTests {
    @Test func parsesWireValueWithEmptyFieldsPreserved() {
        let metadata = RemoteTmuxPaneTitleMetadata(wireValue: "build\u{1f}host.example\u{1f}host")

        #expect(metadata?.title == "build")
        #expect(metadata?.host == "host.example")
        #expect(metadata?.hostShort == "host")
    }

    @Test(arguments: ["", "host.example", "HOST", " host.example "])
    func hostDefaultsDoNotBecomeIntentionalTitles(_ title: String) {
        let metadata = RemoteTmuxPaneTitleMetadata(
            title: title,
            host: "host.example",
            hostShort: "host"
        )

        #expect(metadata.intentionalTitle == nil)
    }

    @Test func trimsAndReturnsDeliberateTitle() {
        let metadata = RemoteTmuxPaneTitleMetadata(
            title: "  build: db  ",
            host: "host.example",
            hostShort: "host"
        )

        #expect(metadata.intentionalTitle == "build: db")
    }

    @Test(arguments: ["", "build", "build\u{1f}host"])
    func rejectsMalformedWireValues(_ wireValue: String) {
        #expect(RemoteTmuxPaneTitleMetadata(wireValue: wireValue) == nil)
    }

    @Test func liveTitleRetainsSnapshotHostMetadata() {
        let snapshot = RemoteTmuxPaneTitleMetadata(
            title: "host",
            host: "host.example",
            hostShort: "host"
        )

        let updated = RemoteTmuxPaneTitleMetadata.applyingLiveWireValue("logs", to: snapshot)

        #expect(updated == RemoteTmuxPaneTitleMetadata(
            title: "logs",
            host: "host.example",
            hostShort: "host"
        ))
    }

    @Test func liveTitleBeforeSnapshotIsMergedWithSnapshotDefaults() {
        let live = RemoteTmuxPaneTitleMetadata.applyingLiveWireValue("logs", to: nil)
        let snapshot = RemoteTmuxPaneTitleMetadata(title: "host", host: "host.example", hostShort: "host")

        #expect(live?.applyingSnapshotDefaults(snapshot) == RemoteTmuxPaneTitleMetadata(
            title: "logs", host: "host.example", hostShort: "host"
        ))
    }

    @Test func newerLiveTitlePreventsStaleSnapshotReplacement() {
        #expect(!RemoteTmuxPaneTitleMetadata.snapshotMayReplace(liveRevision: 4, snapshotRevision: 3))
        #expect(RemoteTmuxPaneTitleMetadata.snapshotMayReplace(liveRevision: 3, snapshotRevision: 3))
    }
}
