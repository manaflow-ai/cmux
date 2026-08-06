import Carbon

protocol KeyboardInputSourceReading: Sendable {
    func currentInputSource() -> TISInputSource?
    func currentASCIICapableInputSource() -> TISInputSource?
}
