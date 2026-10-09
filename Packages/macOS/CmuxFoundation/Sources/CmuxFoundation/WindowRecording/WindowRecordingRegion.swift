internal import Foundation

/// A rectangle inside a cmux window, in window points, with its origin at the
/// window's top-left corner.
///
/// Top-left origin matches the captured image and the coordinates
/// `debug.window.screenshot` frames are read in, so an agent that found a
/// feature in one frame can hand the same numbers back to the recorder.
public struct WindowRecordingRegion: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Parses `x,y,width,height`, the form `cmux record --region` accepts.
    public init?(commaSeparated text: String) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [Double] = []
        values.reserveCapacity(4)
        for part in parts {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            values.append(value)
        }
        self.init(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }
}
