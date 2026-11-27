enum TerminalSelectionTranslation {
    static var isSupported: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }
}
