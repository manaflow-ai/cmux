import CmuxNextPages
import Testing

/// RFD 0058: a confirm stays only before an action that can't be undone. The Cloud page's open,
/// sign-in, sign-out and billing ops run on the person's own click with no sheet; delete, spend and
/// exposure ops keep theirs, and page script alone still gets the sheet for every confirmed op.
struct PageClickRunsOpsTests {
    @Test func theCloudPageRunsOnlyItsUndoableOpsOnAClick() {
        let page = PageDescriptor.cloud
        #expect(page.clickRunsOps == ["cmux.cloud.billing.open", "cmux.cloud.auth.sign_in", "cmux.cloud.auth.sign_out",
                                      "cmux.cloud.machine.connect"])
        for op in ["cmux.cloud.machine.delete", "cmux.cloud.snapshot.delete", "cmux.cloud.machine.archive_delete",
                   "cmux.cloud.snapshot.restore", "cmux.cloud.publication.create", "cmux.cloud.firewall.create"] {
            #expect(!page.clickRunsOps.contains(op), "\(op) must keep its sheet")
        }
        // A click-run op is still a confirmed op: the page never calls it directly.
        #expect(page.clickRunsOps.isSubset(of: Set(page.confirmedOps.keys)))
        #expect(page.clickRunsOps.isSubset(of: page.denied))
    }

    @Test func aClickRunOpThatIsNotConfirmedIsDropped() {
        let page = PageDescriptor(id: "cmux.test", resource: "test", namespaces: ["cmux.test."],
                                  confirmedOps: ["cmux.test.a": .custom], clickRunsOps: ["cmux.test.a", "cmux.test.b"])
        #expect(page.clickRunsOps == ["cmux.test.a"])
    }
}

/// RFD 0132: each confirm a click still meets names why it stays; ``PageDescriptor/guardlessConfirms`` is the rest.
struct PageConfirmGuardsTests {
    @Test func everyCloudSheetAClickMeetsNamesItsGuard() {
        let page = PageDescriptor.cloud
        #expect(page.confirmGuards["cmux.cloud.machine.delete"] == .irreversible)
        #expect(page.confirmGuards["cmux.cloud.snapshot.restore"] == .spends)
        #expect(page.confirmGuards["cmux.cloud.publication.create"] == .exposes)
        // The count itself is the cloud-ergonomics probe's to report (confirms_guarding_nothing), not a test's to hold.
        #expect(Set(page.confirmGuards.keys).isSubset(of: Set(page.confirmedOps.keys).subtracting(page.clickRunsOps)))
    }

    @Test func aConfirmWithNoGuardIsGuardlessAndAGuardOnAClickRunOpIsDropped() {
        let page = PageDescriptor(id: "cmux.test", resource: "test", namespaces: ["cmux.test."],
                                  confirmedOps: ["cmux.test.a": .custom, "cmux.test.b": .delete, "cmux.test.c": .custom],
                                  clickRunsOps: ["cmux.test.c"],
                                  confirmGuards: ["cmux.test.b": .irreversible, "cmux.test.c": .spends, "cmux.test.z": .exposes])
        #expect(page.confirmGuards == ["cmux.test.b": .irreversible])
        #expect(page.guardlessConfirms == ["cmux.test.a"])
    }
}

struct PageRunsOnClickTests {
    @Test func onlyTheHostsRecordOfAClickSkipsTheSheet() {
        let page = PageDescriptor.cloud
        let clicked = PageCallContext(page: page.id, userGesture: true, gestureEvent: 12)
        let script = PageCallContext(page: page.id)
        #expect(page.runsOnClick("cmux.cloud.machine.connect", clicked))
        #expect(!page.runsOnClick("cmux.cloud.machine.connect", script))
        #expect(!page.runsOnClick("cmux.cloud.machine.delete", clicked))
        let user = clicked.asConfirmedUser
        #expect(user.isConfirmedUser && user.userGesture && user.gestureEvent == 12)
        #expect(!script.asConfirmedUser.userGesture)
    }
}
