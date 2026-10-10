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

    @Test func parsesPaneRectLabelMetadataWithoutConfusingTitleMarkerText() {
        let parsed = RemoteTmuxPaneTitleMetadata.paneRectLabel(
            from: "0 \"suffix cmux_title_metadata_v1\\037\"cmux_title_metadata_v1\\037build\\037host.example\\037host"
        )

        #expect(parsed?.header == "0 \"suffix cmux_title_metadata_v1\\037\"")
        #expect(parsed?.metadata == RemoteTmuxPaneTitleMetadata(
            title: "build", host: "host.example", hostShort: "host"
        ))
    }
}

struct RemoteTmuxSubscriptionChangeTests {
    @Test func retainsThePaneTargetAndValue() {
        let change = RemoteTmuxSubscriptionChange(
            controlModeLine: "%subscription-changed cmux_title_all $0 @1 1 %5 : tests"
        )

        #expect(change?.name == "cmux_title_all")
        #expect(change?.paneID == 5)
        #expect(change?.value == "tests")
    }

    @Test func preservesEmptyAndSeparatorlessValues() {
        let empty = RemoteTmuxSubscriptionChange(
            controlModeLine: "%subscription-changed cmux_title_all $0 @1 1 %5 : "
        )
        let separatorless = RemoteTmuxSubscriptionChange(
            controlModeLine: "%subscription-changed cmux_title_all $0 @1 1 %5"
        )

        #expect(empty?.paneID == 5)
        #expect(empty?.value == "")
        #expect(separatorless?.paneID == 5)
        #expect(separatorless?.value == "")
    }

    @Test func rejectsNonSubscriptionControlLines() {
        #expect(RemoteTmuxSubscriptionChange(controlModeLine: "%window-add @1") == nil)
        #expect(RemoteTmuxSubscriptionChange(controlModeLine: "%subscription-changed") == nil)
    }
}
