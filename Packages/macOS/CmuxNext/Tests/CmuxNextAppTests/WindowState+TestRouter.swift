@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus

/// Tests make windows outside the app's composition root: each such window keeps its focus in an input router of its
/// own. The app's windows take its one router (`AppServices.focusInput`) through `WindowManager`; `WindowState`'s
/// initializers have no default for it, so production code cannot get a private router by accident.
extension WindowState {
    convenience init() {
        self.init(focusInput: FocusInput())
    }

    convenience init(record: WindowRecord) {
        self.init(record: record, focusInput: FocusInput())
    }
}
