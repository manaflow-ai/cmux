import Testing
@testable import CmuxNextBrowser

/// A restored history entry that came from a form submission must never be
/// sent again: WebKit re-POSTs it on restore with no prompt (lane 9
/// prototype, results P1/P2: policy `POST backForward`, then
/// `POST formResubmitted`).
struct RestorePostGuardTests {
    @Test func restoredPostsAreCancelled() {
        for type in [RestorePostGuard.NavigationType.backForward, .formResubmitted, .reload, .other] {
            #expect(RestorePostGuard.shouldCancel(restoring: true, isMainFrame: true, method: "POST", type: type), "\(type)")
        }
    }

    @Test func userFormSubmissionsAndGetsPass() {
        #expect(!RestorePostGuard.shouldCancel(restoring: true, isMainFrame: true, method: "GET", type: .backForward))
        #expect(!RestorePostGuard.shouldCancel(restoring: true, isMainFrame: false, method: "POST", type: .backForward))
        #expect(!RestorePostGuard.shouldCancel(restoring: false, isMainFrame: true, method: "POST", type: .formSubmitted))
        #expect(!RestorePostGuard.shouldCancel(restoring: true, isMainFrame: true, method: "POST", type: .formSubmitted),
                "a form the user submits during restore is not a replay")
    }

    @Test func methodsCompareWithoutCase() {
        #expect(RestorePostGuard.shouldCancel(restoring: true, isMainFrame: true, method: "post", type: .backForward))
    }
}

/// The one-shot seed that gives a duplicate tab its original's top-origin
/// sessionStorage (interactionState does not carry it; prototype C1/D5).
struct DuplicateSessionSeedTests {
    @Test func theSeedWritesOnlyOnTheOriginalOrigin() {
        let source = DuplicateSessionSeed(origin: "https://a.test", items: ["k": "v\"</script>", "n": "1"]).scriptSource
        #expect(source.contains("location.origin !== \"https://a.test\""))
        #expect(source.contains("sessionStorage.setItem"))
        #expect(source.contains(#""k":"v\"<\/script>""#) || source.contains(#""k":"v\"</script>""#))
        #expect(!source.contains("</script>"), "page-safe JSON")
    }

    @Test func anEmptySeedHasNoScript() {
        #expect(DuplicateSessionSeed(origin: "https://a.test", items: [:]).scriptSource.isEmpty)
    }
}
