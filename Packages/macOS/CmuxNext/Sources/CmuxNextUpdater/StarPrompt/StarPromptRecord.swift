public import Foundation

/// What the GitHub star prompt remembers on this Mac (``StarPromptCenter``): when cmux first launched, how
/// many launches it has had, the launch the prompt showed in, and whether it is done for good. Kept in the
/// app's defaults with the tips' own record (`TipState`), so it survives updates and relaunches.
nonisolated public struct StarPromptRecord: Equatable, Sendable {
    /// The first launch this record saw; nil before any.
    public var firstLaunchAt: Date?
    /// Launches counted so far (this one included once ``StarPromptCenter/recordLaunch()`` ran).
    public var launches = 0
    /// The launch (``launches`` at the time) the prompt was first on screen in; nil: never shown.
    public var shownInLaunch: Int?
    /// The prompt never shows again: its x or its button was pressed, or it had a whole launch on screen.
    public var done = false

    static let firstLaunchKey = "cmux.next.starPrompt.firstLaunchAt"
    static let launchesKey = "cmux.next.starPrompt.launches"
    static let shownInLaunchKey = "cmux.next.starPrompt.shownInLaunch"
    static let doneKey = "cmux.next.starPrompt.done"

    /// An empty record (a fresh install).
    public init() {}

    /// The record kept in `defaults`.
    public init(defaults: UserDefaults) {
        firstLaunchAt = defaults.object(forKey: Self.firstLaunchKey) as? Date
        launches = defaults.integer(forKey: Self.launchesKey)
        shownInLaunch = defaults.object(forKey: Self.shownInLaunchKey) as? Int
        done = defaults.bool(forKey: Self.doneKey)
    }

    /// Writes the record to `defaults`.
    public func save(to defaults: UserDefaults) {
        defaults.set(firstLaunchAt, forKey: Self.firstLaunchKey)
        defaults.set(launches, forKey: Self.launchesKey)
        defaults.set(shownInLaunch, forKey: Self.shownInLaunchKey)
        defaults.set(done, forKey: Self.doneKey)
    }

    /// Forgets the record (a debug reset to a fresh install).
    static func remove(from defaults: UserDefaults) {
        for key in [firstLaunchKey, launchesKey, shownInLaunchKey, doneKey] { defaults.removeObject(forKey: key) }
    }
}
