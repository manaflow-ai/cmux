internal import Foundation

/// The bounds every `window.record.start` request is held to.
///
/// One recording writes frames for as long as it runs, so the caller cannot be
/// trusted with an unbounded frame rate, duration, or pixel count: a stuck
/// agent would fill the disk. These are the limits the socket enforces; the
/// recorder stops itself at `maximumSeconds` even when nobody calls stop.
public struct WindowRecordingLimits: Sendable {
    public static let framesPerSecond = 1...30
    public static let seconds = 0.5...120.0
    public static let scale = 0.1...1.0
    public static let maximumWidth = 64...4096
    public static let minimumRegionExtent: Double = 8
}

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
                let minimum = Int(WindowRecordingLimits.minimumRegionExtent)
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
        // The format is decoded first and outside the translating `do`, because
        // two of this type's failures name the format the path was checked
        // against, so there is no honest message to build without it.
        let format = try decodeFormat(params["format"])
        do {
            return try makeDecoded(params: params, format: format)
        } catch let failure as WindowCaptureValueFailure {
            throw Failure(failure, format: format)
        }
    }

    private static func makeDecoded(
        params: [String: Any],
        format: Format
    ) throws -> WindowRecordingRequest {
        let framesPerSecond = try WindowCaptureValueDecoding.int(
            params["fps"],
            field: "fps",
            range: WindowRecordingLimits.framesPerSecond
        )
        let maximumSeconds = try WindowCaptureValueDecoding.double(
            params["max_seconds"],
            field: "max_seconds",
            range: WindowRecordingLimits.seconds
        )
        let scale = try WindowCaptureValueDecoding.double(
            params["scale"],
            field: "scale",
            range: WindowRecordingLimits.scale
        )
        let maximumWidth = try WindowCaptureValueDecoding.int(
            params["max_width"],
            field: "max_width",
            range: WindowRecordingLimits.maximumWidth
        )
        let region = try WindowCaptureValueDecoding.region(
            params["region"],
            minimumExtent: WindowRecordingLimits.minimumRegionExtent
        )
        let outputPath = try WindowCaptureValueDecoding.outputPath(
            params["out"],
            extensions: [format.rawValue]
        )

        return WindowRecordingRequest(
            target: region.map { Target.region($0) } ?? .window,
            windowHandle: WindowCaptureValueDecoding.trimmedNonEmpty(params["window"]),
            format: format,
            framesPerSecond: framesPerSecond,
            maximumSeconds: maximumSeconds ?? 15,
            scale: scale,
            maximumWidth: maximumWidth.map { Optional($0) },
            label: WindowRecordingLabel(params["label"] as? String ?? "").value,
            outputPath: outputPath,
            drawsCaptions: WindowCaptureValueDecoding.bool(params["captions"]) ?? true
        )
    }

    private static func decodeFormat(_ value: Any?) throws -> Format {
        guard let raw = WindowCaptureValueDecoding.trimmedNonEmpty(value) else { return .mp4 }
        guard let format = Format(rawValue: raw.lowercased()) else {
            throw Failure.unknownFormat(raw)
        }
        return format
    }
}

private extension WindowRecordingRequest.Failure {
    /// Restates a shared decoding failure in this request's own terms, so the
    /// messages the socket returns stay the ones `window.record.start` has
    /// always returned.
    init(_ failure: WindowCaptureValueFailure, format: WindowRecordingRequest.Format) {
        switch failure {
        case let .notANumber(field):
            self = .notANumber(field: field)
        case let .outOfRange(field, message):
            self = .outOfRange(field: field, message: message)
        case let .malformedRegion(value):
            self = .malformedRegion(value)
        case .regionTooSmall:
            self = .regionTooSmall
        case let .outputPathNotAbsolute(path):
            self = .outputPathNotAbsolute(path)
        case let .outputExtensionMismatch(path):
            self = .outputExtensionMismatch(path: path, format: format)
        }
    }
}
