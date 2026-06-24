#if DEBUG
extension MobileShellComposite {
    /// Test-only: true while a mounted Ghostty surface still has an output consumer.
    func debugHasTerminalOutputSinkForTesting(surfaceID: String) -> Bool {
        hasTerminalOutputSink(surfaceID: surfaceID)
    }
}
#endif
