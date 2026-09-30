internal import Foundation

/// One validated `window.record.start` request.
public struct WindowRecordingRequest: Equatable, Sendable {
    public enum Format: String, Sendable, CaseIterable {
        case mp4
        case gif

        /// Frame rate used when the caller does not ask for one.
        ///
        /// A gif carries one palette and one frame per delay slot, so it stays
        /// slower and smaller than the mp4 default.
        public var defaultFramesPerSecond: Int {
            switch self {
            case .mp4: 12
            case .gif: 8
            }
        }

        /// Scale used when the caller does not ask for one.
        public var defaultScale: Double {
            switch self {
            case .mp4: 1
            case .gif: 0.5
            }
        }

        /// Width cap used when the caller does not ask for one.
        ///
        /// A full-resolution gif of a cmux window runs to tens of megabytes,
        /// which no pull request body wants, so gifs get a default cap and mp4
        /// keeps the window's own size.
        public var defaultMaximumWidth: Int? {
            switch self {
            case .mp4: nil
            case .gif: 960
            }
        }
    }

    /// What the recorder frames.
    public enum Target: Equatable, Sendable {
        /// A whole cmux window: the one named by `window`, else the same window
        /// `debug.window.screenshot` picks.
        case window
        /// A rectangle inside that window.
        case region(WindowRecordingRegion)
    }

    public enum Failure: Error, Equatable, Sendable {
        case unknownFormat(String)
        case notANumber(field: String)
        case outOfRange(field: String, message: String)
        case malformedRegion(String)
        case regionTooSmall
        case outputPathNotAbsolute(String)
        case outputExtensionMismatch(path: String, format: Format)

        /// The message the socket returns with `invalid_params`.
        public var message: String {
            switch self {
            case let .unknownFormat(value):
                let known = Format.allCases.map(\.rawValue).joined(separator: ", ")
                return "unknown format '\(value)'; expected one of \(known)"
            case let .notANumber(field):
                return "\(field) must be a number"
            case let .outOfRange(field, message):
                return "\(field) \(message)"
            case let .malformedRegion(value):
                return "region '\(value)' must be x,y,width,height in window points"
            case .regionTooSmall:
                let minimum = Int(WindowRecordingRequest.minimumRegionExtent)
                return "region width and height must each be at least \(minimum) points"
            case let .outputPathNotAbsolute(path):
                return "out '\(path)' must be an absolute path"
            case let .outputExtensionMismatch(path, format):
                return "out '\(path)' must end in .\(format.rawValue) for format \(format.rawValue)"
            }
        }
    }

    public let target: Target
    public let windowHandle: String?
    public let format: Format
    public let framesPerSecond: Int
    public let maximumSeconds: Double
    public let scale: Double
    public let maximumWidth: Int?
    public let label: String
    public let outputPath: String?
    public let drawsCaptions: Bool

    public init(
        target: Target = .window,
        windowHandle: String? = nil,
        format: Format = .mp4,
        framesPerSecond: Int? = nil,
        maximumSeconds: Double = 15,
        scale: Double? = nil,
        maximumWidth: Int?? = nil,
        label: String = "",
        outputPath: String? = nil,
        drawsCaptions: Bool = true
    ) {
        self.target = target
        self.windowHandle = windowHandle
        self.format = format
        self.framesPerSecond = framesPerSecond ?? format.defaultFramesPerSecond
        self.maximumSeconds = maximumSeconds
        self.scale = scale ?? format.defaultScale
        self.maximumWidth = maximumWidth ?? format.defaultMaximumWidth
        self.label = label
        self.outputPath = outputPath
        self.drawsCaptions = drawsCaptions
    }

    /// The number of frames this request may write before it stops itself.
    public var frameBudget: Int {
        max(1, Int((maximumSeconds * Double(framesPerSecond)).rounded(.up)))
    }

    /// Seconds between two frames.
    public var frameInterval: Double {
        1 / Double(framesPerSecond)
    }

    /// Validates one decoded `window.record.start` parameter dictionary.
    ///
    /// Absent keys take the format's defaults, so `{}` is a complete request:
    /// a 15 second mp4 of the selected window.
    public static func make(params: [String: Any]) throws -> WindowRecordingRequest {
        let format = try decodeFormat(params["format"])
        let framesPerSecond = try decodeInt(
            params["fps"],
            field: "fps",
            range: Self.allowedFramesPerSecond
        )
        let maximumSeconds = try decodeDouble(
            params["max_seconds"],
            field: "max_seconds",
            range: Self.allowedSeconds
        )
        let scale = try decodeDouble(
            params["scale"],
            field: "scale",
            range: Self.allowedScale
        )
        let maximumWidth = try decodeInt(
            params["max_width"],
            field: "max_width",
            range: Self.allowedMaximumWidth
        )
        let target = try decodeTarget(params["region"])
        let outputPath = try decodeOutputPath(params["out"], format: format)

        return WindowRecordingRequest(
            target: target,
            windowHandle: (params["window"] as? String)?.trimmedNonEmpty,
            format: format,
            framesPerSecond: framesPerSecond,
            maximumSeconds: maximumSeconds ?? 15,
            scale: scale,
            maximumWidth: maximumWidth.map { Optional($0) },
            label: WindowRecordingLabel(params["label"] as? String ?? "").value,
            outputPath: outputPath,
            drawsCaptions: decodeBool(params["captions"]) ?? true
        )
    }

    private static func decodeFormat(_ value: Any?) throws -> Format {
        guard let raw = (value as? String)?.trimmedNonEmpty else { return .mp4 }
        guard let format = Format(rawValue: raw.lowercased()) else {
            throw Failure.unknownFormat(raw)
        }
        return format
    }

    private static func decodeTarget(_ value: Any?) throws -> Target {
        guard let value else { return .window }
        let region: WindowRecordingRegion
        if let text = value as? String {
            guard let parsed = WindowRecordingRegion(commaSeparated: text) else {
                throw Failure.malformedRegion(text)
            }
            region = parsed
        } else if let numbers = value as? [Any] {
            let doubles = numbers.compactMap { numericValue($0) }
            guard doubles.count == 4 else {
                throw Failure.malformedRegion(String(describing: value))
            }
            region = WindowRecordingRegion(
                x: doubles[0],
                y: doubles[1],
                width: doubles[2],
                height: doubles[3]
            )
        } else {
            throw Failure.malformedRegion(String(describing: value))
        }
        guard region.isFinite else {
            throw Failure.malformedRegion(String(describing: value))
        }
        guard region.width >= Self.minimumRegionExtent,
              region.height >= Self.minimumRegionExtent else {
            throw Failure.regionTooSmall
        }
        return .region(region)
    }

    private static func decodeOutputPath(_ value: Any?, format: Format) throws -> String? {
        guard let path = (value as? String)?.trimmedNonEmpty else { return nil }
        guard path.hasPrefix("/") else {
            throw Failure.outputPathNotAbsolute(path)
        }
        guard path.lowercased().hasSuffix(".\(format.rawValue)") else {
            throw Failure.outputExtensionMismatch(path: path, format: format)
        }
        return path
    }

    private static func decodeInt(
        _ value: Any?,
        field: String,
        range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value else { return nil }
        guard let number = numericValue(value), number.isFinite else {
            throw Failure.notANumber(field: field)
        }
        // `Int(exactly:)` rather than `Int(_:)`: converting a value past Int's
        // range traps, and "--fps 1e30" is something a caller can type.
        guard let rounded = Int(exactly: number.rounded()), range.contains(rounded) else {
            throw Failure.outOfRange(
                field: field,
                message: "must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return rounded
    }

    private static func decodeDouble(
        _ value: Any?,
        field: String,
        range: ClosedRange<Double>
    ) throws -> Double? {
        guard let value else { return nil }
        guard let number = numericValue(value), number.isFinite else {
            throw Failure.notANumber(field: field)
        }
        guard range.contains(number) else {
            throw Failure.outOfRange(
                field: field,
                message: "must be between \(Self.trim(range.lowerBound)) and \(Self.trim(range.upperBound))"
            )
        }
        return number
    }

    private static func decodeBool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        guard let text = (value as? String)?.trimmedNonEmpty?.lowercased() else { return nil }
        switch text {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

private extension String {
    /// Nil for a blank value, so an empty socket string means "not supplied".
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The bounds every `window.record.start` request is held to.
///
/// One recording writes frames for as long as it runs, so the caller cannot be
/// trusted with an unbounded frame rate, duration, or pixel count: a stuck
/// agent would fill the disk. These are the limits the socket enforces; the
/// recorder stops itself at `maximumSeconds` even when nobody calls stop.
extension WindowRecordingRequest {
    public static let allowedFramesPerSecond = 1...30
    public static let allowedSeconds = 0.5...120.0
    public static let allowedScale = 0.1...1.0
    public static let allowedMaximumWidth = 64...4096
    public static let minimumRegionExtent: Double = 8
}
