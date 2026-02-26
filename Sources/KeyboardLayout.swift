import Carbon

class KeyboardLayout {
    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = Unmanaged<CFString>.fromOpaque(sourceIdPointer).takeUnretainedValue()
            return sourceId as String
        }

        return nil
    }
}
