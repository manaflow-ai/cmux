extension MobileMacConnectionRegistry {
    /// Dictionary-like compatibility view whose keyed reads and writes stay
    /// O(1). Enumeration snapshots only the control entries once.
    @MainActor
    struct ControlSubscriptions: @MainActor Sequence {
        typealias Element = (key: String, value: SecondaryMacSubscription)

        unowned let registry: MobileMacConnectionRegistry

        subscript(macDeviceID: String) -> SecondaryMacSubscription? {
            get { registry.controlSubscription(for: macDeviceID) }
            nonmutating set {
                registry.setControlSubscription(newValue, for: macDeviceID)
            }
        }

        var keys: [String] {
            registry.controlEntries.map(\.key)
        }

        var count: Int {
            registry.controlEntryCount
        }

        var isEmpty: Bool {
            count == 0
        }

        func makeIterator() -> Array<Element>.Iterator {
            registry.controlEntries.makeIterator()
        }

        func removeAll() {
            registry.removeAllControlSubscriptions()
        }
    }
}
