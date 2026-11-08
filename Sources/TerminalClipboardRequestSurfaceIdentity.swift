import CmuxTerminal

/// Fences one clipboard request to the native surface lifetime that admitted it.
struct TerminalClipboardRequestSurfaceIdentity: Equatable, Sendable {
    let surfaceAddress: UInt
    let generation: UInt64

    @MainActor
    init?(terminalSurface: TerminalSurface?) {
        guard let terminalSurface,
              let surface = terminalSurface.surface else { return nil }
        self.init(
            surfaceAddress: UInt(bitPattern: surface),
            generation: terminalSurface.runtimeSurfaceGeneration
        )
    }

    init(surfaceAddress: UInt, generation: UInt64) {
        self.surfaceAddress = surfaceAddress
        self.generation = generation
    }

    @MainActor
    func matches(_ terminalSurface: TerminalSurface?) -> Bool {
        guard let terminalSurface,
              let surface = terminalSurface.surface else { return false }
        return matches(
            surfaceAddress: UInt(bitPattern: surface),
            generation: terminalSurface.runtimeSurfaceGeneration
        )
    }

    func matches(surfaceAddress: UInt, generation: UInt64) -> Bool {
        self.surfaceAddress == surfaceAddress && self.generation == generation
    }
}
