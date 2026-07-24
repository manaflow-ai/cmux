struct KeyboardLayoutKeyIdentityTracker {
    private var pressedCodepoints: [UInt16: UInt32] = [:]

    mutating func codepointForKeyDown(
        keyCode: UInt16,
        resolvedCodepoint: UInt32,
        isRepeat: Bool
    ) -> UInt32 {
        if isRepeat, let pressedCodepoint = pressedCodepoints[keyCode] {
            return pressedCodepoint
        }
        pressedCodepoints[keyCode] = resolvedCodepoint
        return resolvedCodepoint
    }

    mutating func codepointForKeyUp(keyCode: UInt16) -> UInt32? {
        pressedCodepoints.removeValue(forKey: keyCode)
    }

    mutating func reset() {
        pressedCodepoints.removeAll(keepingCapacity: true)
    }
}
