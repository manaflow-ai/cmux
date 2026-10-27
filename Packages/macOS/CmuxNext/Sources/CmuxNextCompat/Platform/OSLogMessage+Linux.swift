// The Linux Logger's message, whose values are read only when it is written (Logger+Linux.swift).

#if !canImport(os)
public import Foundation

/// A log message: a string literal whose interpolations take `privacy:`, `format:` and `align:`
/// (`os.OSLogMessage`).
public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    private let interpolation: OSLogInterpolation

    public init(stringLiteral value: String) {
        var interpolation = OSLogInterpolation(literalCapacity: value.utf8.count, interpolationCount: 0)
        interpolation.appendLiteral(value)
        self.interpolation = interpolation
    }

    public init(stringInterpolation: OSLogInterpolation) {
        interpolation = stringInterpolation
    }

    /// The message's text: each value read now and written under its privacy, format and alignment.
    func render() -> String {
        interpolation.segments.reduce(into: "") { text, segment in text += segment() }
    }
}

/// The interpolations a log message accepts (`os.OSLogInterpolation`). Each value is kept as a closure and read
/// only when the message is written.
public struct OSLogInterpolation: StringInterpolationProtocol {
    var segments: [() -> String] = []

    public init(literalCapacity: Int, interpolationCount: Int) {
        segments.reserveCapacity(interpolationCount * 2 + 1)
    }

    public mutating func appendLiteral(_ literal: String) {
        guard !literal.isEmpty else { return }
        segments.append { literal }
    }

    public mutating func appendInterpolation(
        _ argumentString: @autoclosure @escaping () -> String,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto
    ) {
        segments.append { align.apply(privacy.apply(argumentString(), scalar: false)) }
    }

    // Disfavored as in the os overlay, so that numbers and Booleans take their own overloads.
    @_disfavoredOverload
    public mutating func appendInterpolation<T: CustomStringConvertible>(
        _ value: @autoclosure @escaping () -> T,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto
    ) {
        segments.append { align.apply(privacy.apply(value().description, scalar: false)) }
    }

    public mutating func appendInterpolation(
        _ value: @autoclosure @escaping () -> Any.Type,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto
    ) {
        segments.append { align.apply(privacy.apply(String(describing: value()), scalar: false)) }
    }

    public mutating func appendInterpolation<T: FixedWidthInteger>(
        _ number: @autoclosure @escaping () -> T,
        format: OSLogIntegerFormatting = .decimal,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto
    ) {
        segments.append { align.apply(privacy.apply(format.format(number()), scalar: true)) }
    }

    public mutating func appendInterpolation(
        _ number: @autoclosure @escaping () -> Double,
        format: OSLogFloatFormatting = .fixed,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto
    ) {
        segments.append { align.apply(privacy.apply(format.format(number()), scalar: true)) }
    }

    public mutating func appendInterpolation(
        _ number: @autoclosure @escaping () -> Float,
        format: OSLogFloatFormatting = .fixed,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto
    ) {
        segments.append { align.apply(privacy.apply(format.format(Double(number())), scalar: true)) }
    }

    public mutating func appendInterpolation(
        _ number: @autoclosure @escaping () -> CGFloat,
        format: OSLogFloatFormatting = .fixed,
        align: OSLogStringAlignment = .none,
        privacy: OSLogPrivacy = .auto
    ) {
        segments.append { align.apply(privacy.apply(format.format(Double(number())), scalar: true)) }
    }

    public mutating func appendInterpolation(
        _ boolean: @autoclosure @escaping () -> Bool,
        format: OSLogBoolFormat = .truth,
        privacy: OSLogPrivacy = .auto
    ) {
        segments.append { privacy.apply(boolean() ? format.words.yes : format.words.no, scalar: true) }
    }
}
#endif
