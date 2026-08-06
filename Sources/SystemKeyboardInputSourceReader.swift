import Carbon

/// The platform boundary for retained TIS input-source reads.
struct SystemKeyboardInputSourceReader: KeyboardInputSourceReading {
    func currentInputSource() -> TISInputSource? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    func currentASCIICapableInputSource() -> TISInputSource? {
        TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
    }
}
