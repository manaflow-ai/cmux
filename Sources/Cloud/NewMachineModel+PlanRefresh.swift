extension NewMachineModel {
    /// Reports whether applying a plan refresh would change an observed value.
    /// Cached data is applied before presentation and can arrive again while
    /// the sheet is opening; identical data must not invalidate its layout.
    func planRefreshWouldChange(to updated: NewMachineModel, storedMemoryMb: Int) -> Bool {
        plan != updated.plan
            || availableMemoryOptionsMb != updated.availableMemoryOptionsMb
            || lockedMemoryOptionsMb != updated.lockedMemoryOptionsMb
            || memoryUpgradePlanId != updated.memoryUpgradePlanId
            || memoryUpgradePlansByMb != updated.memoryUpgradePlansByMb
            || vcpusByMemoryMb != updated.vcpusByMemoryMb
            || hasNoAllowedMemoryOptions != updated.hasNoAllowedMemoryOptions
            || planIsLoading
            || planLoadError != nil
            || !availableMemoryOptionsMb.contains(storedMemoryMb)
    }
}
