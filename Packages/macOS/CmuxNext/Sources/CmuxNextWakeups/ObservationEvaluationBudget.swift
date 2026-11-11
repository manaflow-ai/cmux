import CmuxNextCompat

/// The main-thread scheduler's runner of ``ObservationStream`` evaluations (plans/cmux-next/main-thread-scheduling.md,
/// G1): each evaluation is one ``MainWorkClass/visible`` task of ``MainFrameBudget``, owned by its stream's site
/// (`#fileID:#line`). The budget's board names it while it runs (the stall watchdog's records), its time is charged to
/// the frame, so the budgeted work after a long evaluation yields to the next frame, and one that runs past the visible
/// share is reported as over budget. The stream's hop to the main actor stays where it is: no added delay, and one
/// re-evaluation per change burst as before. Installed by ``MainWorkScheduler/runsObservationEvaluations()``.
@MainActor
final class ObservationEvaluationBudget: ObservationEvaluationRunner {
    private let budget: MainFrameBudget
    /// Each site's owner, interned on the board at the site's first evaluation (one lock and one string per site,
    /// about 400 sites in the app; the stream is a plain value with no scheduler at hand where it is made): later
    /// evaluations take one dictionary lookup, no lock and no string.
    private var owners: [ObservationSite: MainTaskOwner] = [:]

    init(budget: MainFrameBudget) {
        self.budget = budget
    }

    func evaluate<T>(at site: ObservationSite, _ body: () -> T) -> T {
        budget.runArrived(.visible, owner: owner(of: site), body)
    }

    private func owner(of site: ObservationSite) -> MainTaskOwner {
        if let owner = owners[site] { return owner }
        let owner = budget.board.owner(site.name)
        owners[site] = owner
        return owner
    }
}
