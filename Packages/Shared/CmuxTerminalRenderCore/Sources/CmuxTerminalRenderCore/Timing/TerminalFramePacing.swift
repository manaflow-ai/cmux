/// The frame rate the renderer asks for. Output-driven frames are on demand
/// (one per vsync at most, none while nothing changes); a display link runs
/// only while a gesture or its deceleration animates, and asks for the
/// device maximum (120 Hz on ProMotion) unless the device is constrained.
public struct TerminalFramePacing: Hashable, Sendable {
    public enum Thermal: Int, Hashable, Sendable, Comparable {
        case nominal, fair, serious, critical
        public static func < (lhs: Thermal, rhs: Thermal) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// `CAFrameRateRange` fields.
    public struct Range: Hashable, Sendable {
        public var minimum: Float
        public var maximum: Float
        public var preferred: Float
        public init(minimum: Float, maximum: Float, preferred: Float) {
            self.minimum = minimum
            self.maximum = maximum
            self.preferred = preferred
        }
    }

    public var thermal: Thermal
    public var lowPowerMode: Bool
    /// The display's maximum (`UIScreen.maximumFramesPerSecond`).
    public var displayMaximum: Int

    public init(thermal: Thermal = .nominal, lowPowerMode: Bool = false, displayMaximum: Int = 120) {
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.displayMaximum = max(displayMaximum, 1)
    }

    /// Serious or critical thermal state, or Low Power Mode (ghostty-next section 9).
    public var isConstrained: Bool { lowPowerMode || thermal >= .serious }

    /// The cap for output-driven frames per second; nil means one per vsync.
    public var outputFrameCap: Int? { isConstrained ? 30 : nil }

    /// Cursor blink is off while constrained.
    public var allowsCursorBlink: Bool { !isConstrained }

    /// The display link range during a scroll, pinch or deceleration.
    public var gestureRange: Range {
        let top = Float(min(displayMaximum, isConstrained ? 30 : 120))
        let floor = Float(min(isConstrained ? 30 : 80, Int(top)))
        return Range(minimum: floor, maximum: top, preferred: top)
    }

    /// The per-frame budget in seconds at the pace the display delivers.
    public var frameBudget: Double {
        1.0 / Double(isConstrained ? 30 : min(displayMaximum, 120))
    }
}
