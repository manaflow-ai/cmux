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

        /// Device-level read of the single focused connection. Get-only:
        /// installing or removing a focus must name the exact pairing key.
        subscript(macDeviceID: String) -> MacConnection? {
            registry.focusedConnection(onDevice: macDeviceID)
        }

        func removeAll() {
            registry.removeAllFocusedConnections()
        }
    }
}
