import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextWakeups

extension SidebarView {
    /// A sidebar on a main-thread scheduler of its own, for rigs that test what it draws rather than how its
    /// work is scheduled (the app passes its one scheduler through `SidebarContainerView`).
    convenience init(model: SidebarModel, design: DesignSettings = .shared, newRows: SidebarNewRowTimer? = nil,
                     responsiveScrolling: Bool = false) {
        self.init(model: model, design: design, mainWork: MainWorkScheduler(budget: MainFrameBudget()), newRows: newRows,
                  responsiveScrolling: responsiveScrolling)
    }
}
