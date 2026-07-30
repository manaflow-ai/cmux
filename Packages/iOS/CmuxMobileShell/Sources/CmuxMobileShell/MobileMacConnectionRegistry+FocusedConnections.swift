extension MobileMacConnectionRegistry {
    /// Dictionary-like compatibility view for the single focused connection.
    @MainActor
    struct FocusedConnections {
        unowned let registry: MobileMacConnectionRegistry

        subscript(macDeviceID: String) -> MacConnection? {
            get { registry.focusedConnection(for: macDeviceID) }
            nonmutating set {
                registry.setFocusedConnection(newValue, for: macDeviceID)
            }
        }

        func removeAll() {
            registry.removeAllFocusedConnections()
        }
    }
}
