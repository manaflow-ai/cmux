nonisolated extension CEFShimLibrary {
    /// Returns a string the shim allocated itself (`cmux_shim_ssl_status`)
    /// and frees it.
    func takeOwnedString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { freeOwned(pointer) }
        return String(cString: pointer)
    }

    /// Returns a fork string as Swift and frees it.
    func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
