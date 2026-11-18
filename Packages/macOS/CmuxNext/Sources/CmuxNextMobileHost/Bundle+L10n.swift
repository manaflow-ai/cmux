import CmuxNextCompat
import Foundation

extension Bundle {
    /// This module's strings: the downloaded language pack's copy of `Bundle.module` once one is
    /// active, else `Bundle.module` (English in a NIGHTLY; CMUX-570, `Bundle.strings`).
    nonisolated static var l10n: Bundle { Bundle.module.strings }
}
