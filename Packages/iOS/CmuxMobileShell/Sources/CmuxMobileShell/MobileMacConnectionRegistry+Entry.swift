extension MobileMacConnectionRegistry {
    struct Entry {
        var controlSubscription: SecondaryMacSubscription?
        var focusedConnection: MacConnection?

        var isEmpty: Bool {
            controlSubscription == nil && focusedConnection == nil
        }
    }
}
