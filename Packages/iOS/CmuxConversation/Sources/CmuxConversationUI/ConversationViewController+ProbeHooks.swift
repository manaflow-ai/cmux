#if canImport(UIKit)
import CmuxConversationCore
import QuartzCore

/// A transcript section the DEBUG scroll probe times (see
/// `ConversationScrollProbe`). The hooks below compile to nothing outside
/// DEBUG and cost one nil check when no probe runs.
enum ConversationProbeSection: String {
    /// `storeDidChange`, everything a store change does on the main thread.
    case storeDidChange = "sdc"
    /// `rebuild`, from the change to the applied rows.
    case rebuild = "reb"
    /// Building the new rows (a page splice, a live tail or a full build).
    case build = "bld"
    /// `measureAhead`'s main-thread part (picking rows, starting the work).
    case measureAhead = "mah"
    /// A measured page coming back to the main thread, up to its rebuild.
    case measured = "mdn"
    /// The row diff of an update.
    case diff = "dif"
    /// `apply`, the whole update.
    case apply = "app"
    /// The batch update and its layout inside `apply`.
    case batch = "bat"
    /// The transcript layout's `prepare` (every row's frame).
    case layoutPrepare = "lay"
}

extension ConversationViewController {
    /// Now, when the probe records; 0 otherwise.
    @inline(__always)
    func probeClock() -> CFTimeInterval {
        #if DEBUG
        return scrollProbe == nil ? 0 : CACurrentMediaTime()
        #else
        return 0
        #endif
    }

    @inline(__always)
    func probeSection(_ section: ConversationProbeSection, since start: CFTimeInterval) {
        #if DEBUG
        scrollProbe?.noteSection(section, start: start)
        #endif
    }

    @inline(__always)
    func probeChange(_ change: ConversationStoreChange) {
        #if DEBUG
        scrollProbe?.noteChange(change)
        #endif
    }

    @inline(__always)
    func probeRestore(_ outcome: @autoclosure () -> String) {
        #if DEBUG
        scrollProbe?.noteRestore(outcome())
        #endif
    }

    @inline(__always)
    func probeCell(_ row: ConversationRow, since start: CFTimeInterval) {
        #if DEBUG
        scrollProbe?.noteCell(row, start: start)
        #endif
    }
}
#endif
