/// Pixel dimensions of the Android emulator's primary display.
public struct AndroidEmulatorDisplaySize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}
