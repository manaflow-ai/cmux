internal import Foundation

/// One validated `window.screenshot` request.
public struct WindowScreenshotRequest: Equatable, Sendable {
    public enum Format: String, Sendable, CaseIterable {
        case png
        case jpeg

        /// Extensions an output path for this format may end in.
        public var fileExtensions: [String] {
            switch self {
            case .png: ["png"]
            case .jpeg: ["jpg", "jpeg"]
            }
        }

        /// Extension used when cmux names the file itself.
        public var preferredFileExtension: String {
            fileExtensions[0]
        }

        /// Whether `quality` means anything for this format.
        public var isLossy: Bool {
            switch self {
            case .png: false
            case .jpeg: true
            }
        }
    }

    /// What the capture frames. Same two targets as a recording, in the same
    /// coordinates, so a region found in a clip can be shot directly.
    public enum Target: Equatable, Sendable {
        case window
        case region(WindowRecordingRegion)
    }

    public enum Failure: Error, Equatable, Sendable {
        case unknownFormat(String)
        case notANumber(field: String)
        case outOfRange(field: String, message: String)
        case malformedRegion(String)
        case regionTooSmall
        case regionTooLarge
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
                let minimum = Int(WindowScreenshotRequest.minimumRegionExtent)
                return "region width and height must each be at least \(minimum) points"
            case .regionTooLarge:
                let maximum = Int(WindowScreenshotRequest.maximumRegionExtent)
                return "region position and size must each stay within \(maximum) points"
            case let .outputPathNotAbsolute(path):
                return "out '\(path)' must be an absolute path"
            case let .outputExtensionMismatch(path, format):
                let expected = format.fileExtensions
                    .map { ".\($0)" }
                    .joined(separator: " or ")
                return "out '\(path)' must end in \(expected) for format \(format.rawValue)"
            }
        }
    }

    public let target: Target
    public let windowHandle: String?
    public let format: Format
    public let scale: Double
    public let maximumWidth: Int?
    public let quality: Double
    public let label: String
    public let outputPath: String?
    public let caption: String?

    public init(
        target: Target = .window,
        windowHandle: String? = nil,
        format: Format = .png,
        scale: Double = 1,
        maximumWidth: Int? = nil,
        quality: Double = 0.8,
        label: String = "",
        outputPath: String? = nil,
        caption: String? = nil
    ) throws {
        guard scale.isFinite, Self.allowedScale.contains(scale) else {
            throw Failure.outOfRange(field: "scale", message: "must be between 0.1 and 1")
        }
        guard quality.isFinite, Self.allowedQuality.contains(quality) else {
            throw Failure.outOfRange(field: "quality", message: "must be between 0.1 and 1")
        }
        if let maximumWidth, !Self.allowedMaximumWidth.contains(maximumWidth) {
            throw Failure.outOfRange(
                field: "max_width",
                message: "must be between \(Self.allowedMaximumWidth.lowerBound) and \(Self.allowedMaximumWidth.upperBound)"
            )
        }
        if case let .region(region) = target {
            guard region.isFinite else {
                throw Failure.malformedRegion(String(describing: region))
            }
            guard region.width >= Self.minimumRegionExtent,
                  region.height >= Self.minimumRegionExtent else {
                throw Failure.regionTooSmall
            }
            guard abs(region.x) <= Self.maximumRegionExtent,
                  abs(region.y) <= Self.maximumRegionExtent,
                  region.width <= Self.maximumRegionExtent,
                  region.height <= Self.maximumRegionExtent else {
                throw Failure.regionTooLarge
            }
        }
        if let outputPath {
            guard outputPath.hasPrefix("/") else {
                throw Failure.outputPathNotAbsolute(outputPath)
            }
            guard outputPath.lowercased().hasSuffix(".\(format.fileExtensions[0])")
                    || format.fileExtensions.dropFirst().contains(where: { outputPath.lowercased().hasSuffix(".\($0)") }) else {
                throw Failure.outputExtensionMismatch(path: outputPath, format: format)
            }
        }

        self.target = target
        self.windowHandle = WindowCaptureValueDecoding.trimmedNonEmpty(windowHandle)
        self.format = format
        self.scale = scale
        self.maximumWidth = maximumWidth
        self.quality = quality
        self.label = WindowRecordingLabel(label, fallback: "screenshot").value
        self.outputPath = outputPath
        self.caption = WindowCaptureValueDecoding.trimmedNonEmpty(caption)
    }

    /// Validates one decoded `window.screenshot` parameter dictionary.
    ///
    /// Absent keys take the defaults, so `{}` is a complete request: a
    /// full-resolution png of the selected window.
    public static func make(params: [String: Any]) throws -> WindowScreenshotRequest {
        // Decoded before the translating `do`, for the same reason as in
        // `WindowRecordingRequest`: a path failure has to name the format.
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
    ) throws -> WindowScreenshotRequest {
        let scale = try WindowCaptureValueDecoding.double(
            params["scale"],
            field: "scale",
            range: Self.allowedScale
        )
        let maximumWidth = try WindowCaptureValueDecoding.int(
            params["max_width"],
            field: "max_width",
            range: Self.allowedMaximumWidth
        )
        let quality = try WindowCaptureValueDecoding.double(
            params["quality"],
            field: "quality",
            range: Self.allowedQuality
        )
        let region = try WindowCaptureValueDecoding.region(
            params["region"],
            minimumExtent: Self.minimumRegionExtent,
            maximumExtent: Self.maximumRegionExtent
        )
        let outputPath = try WindowCaptureValueDecoding.outputPath(
            params["out"],
            extensions: format.fileExtensions
        )

        return try WindowScreenshotRequest(
            target: region.map { Target.region($0) } ?? .window,
            windowHandle: WindowCaptureValueDecoding.trimmedNonEmpty(params["window"]),
            format: format,
            scale: scale ?? 1,
            maximumWidth: maximumWidth,
            quality: quality ?? 0.8,
            label: WindowRecordingLabel(
                params["label"] as? String ?? "",
                fallback: "screenshot"
            ).value,
            outputPath: outputPath,
            caption: WindowCaptureValueDecoding.trimmedNonEmpty(params["caption"])
        )
    }

    private static func decodeFormat(_ value: Any?) throws -> Format {
        guard let raw = WindowCaptureValueDecoding.trimmedNonEmpty(value) else { return .png }
        let lowered = raw.lowercased()
        // "jpg" is what a caller types and what the file is called; the format is
        // named "jpeg" because that is what the image type is called.
        if lowered == "jpg" { return .jpeg }
        guard let format = Format(rawValue: lowered) else {
            throw Failure.unknownFormat(raw)
        }
        return format
    }
}

private extension WindowScreenshotRequest.Failure {
    init(_ failure: WindowCaptureValueFailure, format: WindowScreenshotRequest.Format) {
        switch failure {
        case let .notANumber(field):
            self = .notANumber(field: field)
        case let .outOfRange(field, message):
            self = .outOfRange(field: field, message: message)
        case let .malformedRegion(value):
            self = .malformedRegion(value)
        case .regionTooSmall:
            self = .regionTooSmall
        case .regionTooLarge:
            self = .regionTooLarge
        case let .outputPathNotAbsolute(path):
            self = .outputPathNotAbsolute(path)
        case let .outputExtensionMismatch(path):
            self = .outputExtensionMismatch(path: path, format: format)
        }
    }
}

/// The bounds every `window.screenshot` request is held to.
///
/// A still writes one file and returns, so it needs no duration or frame rate
/// limit: what it can get wrong is size. The width cap is higher than the
/// recorder's because a single png of a 6K window is a reasonable thing to ask
/// for, where 30 frames a second of one is not.
extension WindowScreenshotRequest {
    public static let allowedScale = 0.1...1.0
    public static let allowedMaximumWidth = 64...8192
    public static let allowedQuality = 0.1...1.0
    public static let minimumRegionExtent: Double = 8
    public static let maximumRegionExtent: Double = 100_000
}
