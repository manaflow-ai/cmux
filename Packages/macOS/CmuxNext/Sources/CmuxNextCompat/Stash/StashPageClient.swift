/// The Stashed page's model as its source sees it: the source (CmuxNextStash's `StashService`)
/// sets itself as the model's ``source`` and has it read the stashes again after each stash
/// change, without naming the model's type (the model lives in a higher target, CmuxNextHistory).
@MainActor
package protocol StashPageClient: AnyObject {
    /// Where the model reads the stashes and runs its ops; the model holds it weakly.
    var source: (any StashPageSource)? { get set }
    /// Reads the stashes again; returns once the newest read has landed.
    func reload() async
}
