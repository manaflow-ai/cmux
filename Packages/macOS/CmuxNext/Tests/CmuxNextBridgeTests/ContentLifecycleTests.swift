import Testing
@testable import CmuxNextBridge

/// The tab content lifecycle (plans/cmux-next/tab-lifecycle.md): every
/// visibility change is an event, and a late asynchronous completion can
/// never show or hide the content of a newer selection.
struct ContentLifecycleTests {
    typealias Machine = ContentLifecycle<String>

    private func token(_ effects: [Machine.Effect]) -> Machine.Token? {
        for effect in effects {
            switch effect {
            case .mount(_, let t), .reveal(_, let t), .conceal(_, let t), .release(_, let t), .restore(_, let t): return t
            }
        }
        return nil
    }

    @Test func firstShowMountsAndTheCompletionReveals() {
        var machine = Machine()
        let show = machine.send(.show("a"))
        guard case .mount("a", let pending)? = show.first else { Issue.record("expected mount, got \(show)"); return }
        #expect(machine.phase("a") == .restoring)
        let done = machine.send(.mounted("a", pending))
        #expect(machine.phase("a") == .mountedVisible)
        guard case .reveal("a", _)? = done.first else { Issue.record("expected reveal, got \(done)"); return }
    }

    @Test func aCompletionThatLandsAfterTheTabWasHiddenStaysHidden() {
        var machine = Machine()
        let pending = token(machine.send(.show("a")))!
        _ = machine.send(.hide("a"))
        let done = machine.send(.mounted("a", pending))
        #expect(machine.phase("a") == .mountedHidden)
        guard case .conceal("a", _)? = done.first else { Issue.record("expected conceal, got \(done)"); return }
    }

    @Test func aStaleConcealSnapshotIsRejectedOnceTheTabShowsAgain() {
        // The disappearing-page race: hide A (a snapshot is rendered
        // asynchronously), show A again before it lands. The snapshot's
        // token is no longer current, so it may not hide the page.
        var machine = Machine()
        let pending = token(machine.send(.show("a")))!
        _ = machine.send(.mounted("a", pending))
        let concealed = token(machine.send(.hide("a")))!
        #expect(machine.accepts("a", concealed))
        _ = machine.send(.show("a"))
        #expect(!machine.accepts("a", concealed))
        #expect(machine.phase("a") == .mountedVisible)
    }

    @Test func rapidSelectionsAlternateRevealAndConcealInOrder() {
        var machine = Machine()
        for key in ["a", "b", "c"] {
            let pending = token(machine.send(.show(key)))!
            _ = machine.send(.mounted(key, pending))
            _ = machine.send(.hide(key))
        }
        var shown: String?
        var visible: Set<String> = []
        for step in 0..<300 {
            let next = ["a", "b", "c"][step % 3]
            if let shown { for effect in machine.send(.hide(shown)) { if case .conceal(let k, _) = effect { visible.remove(k) } } }
            for effect in machine.send(.show(next)) { if case .reveal(let k, _) = effect { visible.insert(k) } }
            shown = next
            #expect(visible == [next])
        }
    }

    @Test func hibernateReleasesOnlyHiddenContentAndShowRestores() {
        var machine = Machine()
        let pending = token(machine.send(.show("a")))!
        _ = machine.send(.mounted("a", pending))
        #expect(machine.send(.hibernate("a")).isEmpty)
        _ = machine.send(.hide("a"))
        guard case .release("a", _)? = machine.send(.hibernate("a")).first else { Issue.record("expected release"); return }
        #expect(machine.phase("a") == .hibernated)
        let show = machine.send(.show("a"))
        guard case .restore("a", let restore)? = show.first else { Issue.record("expected restore, got \(show)"); return }
        #expect(machine.phase("a") == .restoring)
        // The user flies past: hide and show again while it restores. The
        // one outstanding restore still completes and shows the page.
        #expect(machine.send(.hide("a")).isEmpty)
        #expect(machine.send(.show("a")).isEmpty)
        guard case .reveal("a", _)? = machine.send(.mounted("a", restore)).first else { Issue.record("expected reveal"); return }
        #expect(machine.phase("a") == .mountedVisible)
    }

    @Test func aCompletionForAClosedOrReleasedTabChangesNothing() {
        var machine = Machine()
        let pending = token(machine.send(.show("a")))!
        _ = machine.send(.removed("a"))
        #expect(machine.send(.mounted("a", pending)).isEmpty)
        #expect(machine.record("a") == nil)

        let again = token(machine.send(.show("b")))!
        _ = machine.send(.released("b"))
        // Released while visible: a new mount starts; the old one is stale.
        #expect(machine.phase("b") == .restoring)
        #expect(machine.send(.mounted("b", again)).isEmpty)
    }

    @Test func crashedContentShowsTheSadTabAndRecovers() {
        var machine = Machine()
        let pending = token(machine.send(.show("a")))!
        _ = machine.send(.mounted("a", pending))
        _ = machine.send(.crashed("a"))
        #expect(machine.phase("a") == .crashed)
        guard case .conceal? = machine.send(.hide("a")).first else { Issue.record("expected conceal"); return }
        guard case .reveal? = machine.send(.show("a")).first else { Issue.record("expected reveal"); return }
        guard case .reveal? = machine.send(.recovered("a")).first else { Issue.record("expected reveal"); return }
        #expect(machine.phase("a") == .mountedVisible)
        #expect(machine.send(.hibernate("a")).isEmpty)
    }
}

extension ContentLifecycleTests {
    @Test func wakeRestoresInTheBackgroundAndStaysHidden() {
        var machine = Machine()
        let pending = token(machine.send(.show("a")))!
        _ = machine.send(.mounted("a", pending))
        _ = machine.send(.hide("a"))
        _ = machine.send(.hibernate("a"))
        let wake = machine.send(.wake("a"))
        guard case .restore("a", let restore)? = wake.first else { Issue.record("expected restore, got \(wake)"); return }
        #expect(machine.send(.wake("a")).isEmpty)
        guard case .conceal("a", _)? = machine.send(.mounted("a", restore)).first else { Issue.record("expected conceal"); return }
        #expect(machine.phase("a") == .mountedHidden)
    }
}

extension ContentLifecycleTests {
    @Test func aFailedRestoreKeepsTheTabHibernatedSoTheNextShowRetries() {
        var machine = Machine()
        _ = machine.send(.mounted("a", token(machine.send(.show("a")))!))
        _ = machine.send(.hide("a"))
        _ = machine.send(.hibernate("a"))
        let restore = token(machine.send(.show("a")))!
        _ = machine.send(.mountFailed("a", restore))
        #expect(machine.phase("a") == .hibernated)
        _ = machine.send(.hide("a"))
        guard case .restore? = machine.send(.show("a")).first else { Issue.record("expected a retry"); return }
    }
}
