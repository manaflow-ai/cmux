import CmuxNextDaemon
import Observation

/// This run's incognito spaces (leo-workspace design/spaces.md "Incognito": normal and incognito content never
/// mix; spaces-incognito-audit leak 9). New Incognito Space marks its space before the daemon creates it, so no
/// frame of a normal window's space bar lists it, and neither does that window's sidebar snapshot (it saves the
/// bar's spaces). Observable: the sidebar's observation reads it with the daemon's profiles. A mark stays after
/// its space is deleted: the daemon may still mirror the space for a moment, and a deleted space lists nowhere.
@Observable
final class IncognitoSpaceMarks {
    private(set) var ids: Set<String> = []

    func mark(_ space: ProfileID) {
        if !ids.contains(space.rawValue) { ids.insert(space.rawValue) }
    }

    /// The spaces a window must not list: every incognito space but `own`, the one an incognito window shows.
    func hidden(except own: ProfileID?) -> Set<String> {
        guard let own else { return ids }
        return ids.subtracting([own.rawValue])
    }
}
