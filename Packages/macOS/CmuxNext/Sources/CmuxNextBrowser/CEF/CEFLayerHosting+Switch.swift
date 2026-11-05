import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// The hosting switches (`browserResize.layerHosting`, S5's `motion.frameOwner.pages`) reach the pages already shown, at once
/// (lead, cmux-ad m14, STATUS 13602: an ON film flipped the switch after its page was up and filmed no hosted page). One per
/// runtime (`CEFRuntime.hostingSwitch`): it observes the two switches, and on a change each shown page window it follows is
/// hosted or given its window back, one fork call per page, in the change's main-actor turn. A hidden page (a parked tab's
/// pane, a pane out of a window) is left for its next show (`CEFLayerHosting.pageShown(browser:)`). No per-frame work: the
/// observation wakes only when the store changes, and an equal value reaches no page.
final class CEFHostingSwitch {
    /// The page windows it follows (`CEFLayerHosting.pageWindowCreated`), weakly; `CEFLayerHosting.stop()` takes one out.
    private let followed = NSHashTable<CEFLayerHosting>.weakObjects()
    /// Lives with the runtime; it ends at its first wake after the switch is gone.
    private var observation: Task<Void, Never>?

    init() {}

    /// Whether either switch wants pages hosted.
    static var hostingWanted: Bool { BrowserResizeTunables.layerHosting.value || BrowserResizeTunables.framesOwnedByCommit.value }

    /// Follows `hosting` from now on; the observation starts with the first page window.
    func follow(_ hosting: CEFLayerHosting) {
        followed.add(hosting)
        guard observation == nil else { return }
        // task-owner: the runtime's observation of two Debug switches; it wakes only when the store changes
        observation = Task { @MainActor [weak self] in
            // The store's revision too: while the store is inactive the switches' own reads register nothing, so the
            // stream wakes again at the store's next write; an equal value is dropped, so other writes reach no page.
            let wanted = ObservationStream {
                _ = TunableStore.shared.revision
                return CEFHostingSwitch.hostingWanted
            }
            for await _ in wanted {
                guard let self else { return }
                for hosting in self.followed.allObjects { hosting.hostingSwitchChanged() }
            }
        }
    }

    /// `hosting`'s page window stopped: no later change reaches it.
    func unfollow(_ hosting: CEFLayerHosting) {
        followed.remove(hosting)
    }
}

extension CEFLayerHosting {
    /// A switch changed (``CEFHostingSwitch``): a shown page takes the new wish now, as a show would (``pageShown(browser:)``:
    /// no fork call when the page already is as wanted).
    func hostingSwitchChanged() {
        guard let browser, let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        pageShown(browser: browser)
    }
}
