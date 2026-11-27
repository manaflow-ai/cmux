internal import Foundation

/// What one capture parameter can be wrong in.
///
/// Neither capture request returns this to a caller: each translates it into its
/// own public failure, whose wording names that method's formats and limits. It
/// exists so the two requests cannot disagree about what "a number", "a region"
/// or "an absolute output path" means.
enum WindowCaptureValueFailure: Error, Equatable {
    case notANumber(field: String)
    case outOfRange(field: String, message: String)
    case malformedRegion(String)
    case regionTooSmall(minimumExtent: Double)
    case regionTooLarge(maximumExtent: Double)
    case outputPathNotAbsolute(String)
    case outputExtensionMismatch(path: String)
}

/// Parameter decoding shared by `window.record.start` and `window.screenshot`.
///
/// Every value arrives from a socket as `Any`, from a CLI flag as a string, and
/// from a JSON tour as a number, so each decoder takes all three. An absent key
/// gives `nil` rather than a failure: the request decides the default.
enum WindowCaptureValueDecoding {
    static func int(
        _ value: Any?,
        field: String,
        range: ClosedRange<Int>
    ) throws -> Int? {
        guard let value else { return nil }
        guard let number = numericValue(value), number.isFinite else {
            throw WindowCaptureValueFailure.notANumber(field: field)
        }
        // Integer fields never round. In particular, a JSON caller's 12.5 fps
        // must not silently become 13, and converting a value past Int's range
        // must not trap.
        guard number.rounded(.towardZero) == number else {
            throw WindowCaptureValueFailure.outOfRange(
                field: field,
                message: "must be a whole number between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        guard let integer = Int(exactly: number), range.contains(integer) else {
            throw WindowCaptureValueFailure.outOfRange(
                field: field,
                message: "must be between \(range.lowerBound) and \(range.upperBound)"
            )
        }
        return integer
    }

    static func double(
        _ value: Any?,
        field: String,
        range: ClosedRange<Double>
    ) throws -> Double? {
        guard let value else { return nil }
        guard let number = numericValue(value), number.isFinite else {
            throw WindowCaptureValueFailure.notANumber(field: field)
        }
        guard range.contains(number) else {
            throw WindowCaptureValueFailure.outOfRange(
                field: field,
                message: "must be between \(trim(range.lowerBound)) and \(trim(range.upperBound))"
            )
        }
        return number
    }

    static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        guard let text = trimmedNonEmpty(value)?.lowercased() else { return nil }
        switch text {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// Accepts `"x,y,w,h"` and `[x, y, w, h]`, the two forms a caller can reach
    /// a region through: a CLI flag and a JSON array.
    static func region(
        _ value: Any?,
        minimumExtent: Double,
        maximumExtent: Double
    ) throws -> WindowRecordingRegion? {
        guard let value else { return nil }
        let region: WindowRecordingRegion
        if let text = value as? String {
            guard let parsed = WindowRecordingRegion(commaSeparated: text) else {
                throw WindowCaptureValueFailure.malformedRegion(text)
            }
            region = parsed
        } else if let numbers = value as? [Any] {
            guard numbers.count == 4 else {
                throw WindowCaptureValueFailure.malformedRegion(String(describing: value))
            }
            var doubles: [Double] = []
            doubles.reserveCapacity(4)
            for value in numbers {
                guard let number = numericValue(value) else {
                    throw WindowCaptureValueFailure.malformedRegion(String(describing: numbers))
                }
                doubles.append(number)
            }
            region = WindowRecordingRegion(
                x: doubles[0],
                y: doubles[1],
                width: doubles[2],
                height: doubles[3]
            )
        } else {
            throw WindowCaptureValueFailure.malformedRegion(String(describing: value))
        }
        guard region.isFinite else {
            throw WindowCaptureValueFailure.malformedRegion(String(describing: value))
        }
        guard region.width >= minimumExtent, region.height >= minimumExtent else {
            throw WindowCaptureValueFailure.regionTooSmall(minimumExtent: minimumExtent)
        }
        guard abs(region.x) <= maximumExtent,
              abs(region.y) <= maximumExtent,
              region.width <= maximumExtent,
              region.height <= maximumExtent else {
            throw WindowCaptureValueFailure.regionTooLarge(maximumExtent: maximumExtent)
        }
        return region
    }

    /// An output path has to be absolute, because the app's working directory is
    /// not the caller's, and it has to name the format it will hold, because a
    /// `.png` full of JPEG bytes is a file every later tool misreads.
    static func outputPath(
        _ value: Any?,
        extensions: [String]
    ) throws -> String? {
        guard let path = trimmedNonEmpty(value) else { return nil }
        guard path.hasPrefix("/") else {
            throw WindowCaptureValueFailure.outputPathNotAbsolute(path)
        }
        let lowered = path.lowercased()
        guard extensions.contains(where: { lowered.hasSuffix(".\($0)") }) else {
            throw WindowCaptureValueFailure.outputExtensionMismatch(path: path)
        }
        return path
    }

    static func numericValue(_ value: Any) -> Double? {
        // Bool bridges to NSNumber, but `true` is not a numeric capture value.
        // Use the Core Foundation identity so an NSNumber containing numeric 1
        // remains valid while the JSON boolean singleton does not.
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Nil for a blank value, so an empty socket string means "not supplied".
    static func trimmedNonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
