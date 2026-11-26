extension MobileMacConnectionRegistry {
    /// Dictionary-like compatibility view whose keyed reads and writes stay
    /// O(1). Enumeration snapshots only the control entries once.
    @MainActor
    struct ControlSubscriptions: @MainActor Sequence {
        typealias Element = (key: MacPairingKey, value: SecondaryMacSubscription)

        unowned let registry: MobileMacConnectionRegistry

        subscript(ownerKey: MacPairingKey) -> SecondaryMacSubscription? {
            get { registry.controlSubscription(for: ownerKey) }
            nonmutating set {
                registry.setControlSubscription(newValue, for: ownerKey)
            }
        }

        var keys: [MacPairingKey] {
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
