@MainActor
// lint:allow free-function - internal package helper warmControlPoolHasCapacity, preserving existing call sites during UI closeout.
func warmControlPoolHasCapacity(
    currentControlCount: Int,
    vacatesControlSlot: Bool
) -> Bool {
    currentControlCount - (vacatesControlSlot ? 1 : 0)
        < MobileShellComposite.maximumWarmControlConnectionCount
}
