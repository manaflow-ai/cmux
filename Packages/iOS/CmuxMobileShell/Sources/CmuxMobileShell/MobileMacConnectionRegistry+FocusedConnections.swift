extension MobileMacConnectionRegistry {
    /// Dictionary-like compatibility view for the single focused connection.
    @MainActor
    struct FocusedConnections {
        unowned let registry: MobileMacConnectionRegistry

        subscript(ownerKey: MacPairingKey) -> MacConnection? {
            get { registry.focusedConnection(for: ownerKey) }
            nonmutating set {
                registry.setFocusedConnection(newValue, for: ownerKey)
            }
        }

        /// Compatibility read accepting either a bare legacy id or a composite
        /// pairing id. It always resolves one exact owner key.
        subscript(macDeviceID: String) -> MacConnection? {
            registry.focusedConnection(for: MacPairingKey(pairingID: macDeviceID))
        }

        /// Resolve the one focused owner on a physical Mac regardless of the
        /// stored versus authenticated instance tag.
        func onDevice(_ macDeviceID: String) -> MacConnection? {
            registry.focusedConnection(onDevice: macDeviceID)
        }

        func removeAll() {
            registry.removeAllFocusedConnections()
        }
    }
}
