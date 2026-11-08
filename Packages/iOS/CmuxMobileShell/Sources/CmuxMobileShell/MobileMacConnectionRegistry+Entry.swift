extension MobileMacConnectionRegistry {
    /// Registry capabilities are optional because focus and control may share
    /// one peer entry independently.
    struct Entry {
        var controlSubscription: SecondaryMacSubscription? = nil
        var focusedConnection: MacConnection? = nil

        var isEmpty: Bool {
            controlSubscription == nil && focusedConnection == nil
        }
    }
}
