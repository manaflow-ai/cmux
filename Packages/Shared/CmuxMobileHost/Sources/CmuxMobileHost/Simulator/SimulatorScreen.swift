/// A simulator's screen: size in points and its pixel scale.
public struct SimulatorScreen: Hashable, Sendable {
    public var pointWidth: Double
    public var pointHeight: Double
    public var scale: Double

    public init(pointWidth: Double, pointHeight: Double, scale: Double) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
    }
}
