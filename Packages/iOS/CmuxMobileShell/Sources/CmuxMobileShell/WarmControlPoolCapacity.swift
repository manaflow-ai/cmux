@MainActor
func warmControlPoolHasCapacity(
    currentControlCount: Int,
    vacatesControlSlot: Bool
) -> Bool {
    currentControlCount - (vacatesControlSlot ? 1 : 0)
        < MobileShellComposite.maximumWarmControlConnectionCount
}
