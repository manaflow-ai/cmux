import Foundation
import QuartzCore

extension MotionPath {
    /// What an animation's values are, read once per value list: then each value is read with no string work
    /// (a `CGPoint` or `CGSize` `NSValue`, or an `NSNumber` for a component path).
    enum ValueKind {
        case point, size, number

        /// The kind of `value`; nil for one the path cannot read. Compares the value's type encoding with
        /// `strcmp` against the two it reads (no `String` built).
        init?(of value: Any?) {
            if value is NSNumber {
                self = .number
                return
            }
            guard let value = value as? NSValue else { return nil }
            let type = value.objCType
            if strcmp(type, Self.pointType) == 0 {
                self = .point
            } else if strcmp(type, Self.sizeType) == 0 {
                self = .size
            } else {
                return nil
            }
        }

        /// `value` as (x, y) (a size as (width, height), a number in x); nil when it is not this kind.
        func point(_ value: Any?) -> CGPoint? {
            switch self {
            case .number: (value as? NSNumber).map { CGPoint(x: CGFloat($0.doubleValue), y: 0) }
            case .point: (value as? NSValue).map { $0.pointValue }
            case .size: (value as? NSValue).map { CGPoint(x: $0.sizeValue.width, y: $0.sizeValue.height) }
            }
        }

        // The type encodings an NSValue of a CGPoint or CGSize reports, copied once (NUL-terminated constants).
        private static let pointType: [CChar] = Array(String(cString: NSValue(point: .zero).objCType).utf8CString)
        private static let sizeType: [CChar] = Array(String(cString: NSValue(size: .zero).objCType).utf8CString)
    }
}
