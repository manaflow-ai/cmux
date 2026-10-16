import Foundation

/// Decodes the `NSColor` and `NSFont` archives Terminal stores in its profiles, without AppKit.
///
/// `NSKeyedUnarchiver` is pointed at small stand-in classes that read the same
/// keys AppKit writes (`NSRGB`, `NSWhite`, `NSColorSpace`, `NSName`, `NSSize`),
/// so the package stays free of AppKit and decodes identically everywhere.
/// Secure coding stays on: only the stand-ins may appear in an archive, so a
/// crafted preferences value cannot instantiate any other class.
struct KeyedArchiveValueDecoder {
    /// A decoded color with its alpha, which Terminal uses for window opacity.
    struct Color: Equatable {
        var color: TerminalColor
        var alpha: Double
    }

    /// A decoded font.
    struct Font: Equatable {
        var postScriptName: String
        var size: Double
    }

    func color(from data: Data) -> Color? {
        guard let archived = unarchive(data, as: ArchivedColor.self, className: "NSColor") else { return nil }
        return archived.decoded
    }

    func font(from data: Data) -> Font? {
        guard let archived = unarchive(data, as: ArchivedFont.self, className: "NSFont"),
              let name = archived.name else { return nil }
        return Font(postScriptName: name, size: archived.size)
    }

    private func unarchive<T: NSObject>(_ data: Data, as type: T.Type, className: String) -> T? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(type, forClassName: className)
        unarchiver.setClass(ArchivedColorSpace.self, forClassName: "NSColorSpace")
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(
            of: [type as AnyClass, ArchivedColorSpace.self as AnyClass],
            forKey: NSKeyedArchiveRootObjectKey
        ) as? T
    }
}

/// Stand-in for an archived `NSColor`.
@objc(CmuxTerminalImportArchivedColor)
private final class ArchivedColor: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let decoded: KeyedArchiveValueDecoder.Color?

    func encode(with coder: NSCoder) {}

    init?(coder: NSCoder) {
        let space = coder.decodeInteger(forKey: "NSColorSpace")
        // 1 calibrated RGB, 2 device RGB, 3 calibrated white, 4 device white.
        switch space {
        case 1, 2:
            guard let values = Self.numbers(coder, key: "NSRGB"), values.count >= 3 else { return nil }
            let color = TerminalColor(
                red: values[0], green: values[1], blue: values[2],
                space: space == 1 ? .genericRGB : .deviceRGB
            )
            decoded = .init(color: color, alpha: values.count > 3 ? values[3] : 1)
        case 3, 4:
            guard let values = Self.numbers(coder, key: "NSWhite"), let white = values.first else { return nil }
            decoded = .init(
                color: TerminalColor(red: white, green: white, blue: white),
                alpha: values.count > 1 ? values[1] : 1
            )
        default:
            // Catalog and custom-space colors carry `NSComponents`; read them as sRGB.
            guard let values = Self.numbers(coder, key: "NSComponents"), values.count >= 3 else { return nil }
            decoded = .init(
                color: TerminalColor(red: values[0], green: values[1], blue: values[2]),
                alpha: values.count > 3 ? values[3] : 1
            )
        }
        super.init()
    }

    /// Reads a space-separated, NUL-terminated ASCII number list such as `"0.1 0.2 0.3 1\0"`.
    private static func numbers(_ coder: NSCoder, key: String) -> [Double]? {
        var length = 0
        guard let bytes = coder.decodeBytes(forKey: key, returnedLength: &length), length > 0 else { return nil }
        let data = Data(bytes: bytes, count: length)
        guard let text = String(data: data, encoding: .ascii) else { return nil }
        let values = text
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
            .split(separator: " ")
            .compactMap { ConfigValue.decimal(String($0)) }
        return values.isEmpty ? nil : values
    }
}

/// Stand-in for an archived `NSColorSpace`, decoded and ignored.
@objc(CmuxTerminalImportArchivedColorSpace)
private final class ArchivedColorSpace: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    func encode(with coder: NSCoder) {}
    init?(coder: NSCoder) { super.init() }
}

/// Stand-in for an archived `NSFont`.
@objc(CmuxTerminalImportArchivedFont)
private final class ArchivedFont: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let name: String?
    let size: Double

    func encode(with coder: NSCoder) {}

    init?(coder: NSCoder) {
        name = coder.decodeObject(of: NSString.self, forKey: "NSName") as String?
        size = coder.decodeDouble(forKey: "NSSize")
        super.init()
    }
}
