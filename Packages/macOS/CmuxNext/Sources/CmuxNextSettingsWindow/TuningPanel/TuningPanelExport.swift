public import CmuxNextDesign
import Foundation

/// The tuning panel's "Copy Values" text: every value the panel shows as a Swift constant, tuned or not, so the
/// whole surface's numbers can be pasted into code in one go. Pure, so a test checks the text without a window.
public nonisolated struct TuningPanelExport: Sendable {
    /// The Swift type of a choice tunable's constant (`NSFont.Weight` for a weight); nil prints the raw choice
    /// as a string literal.
    public var choiceType: @Sendable (TunableDescriptor) -> String?

    /// - Parameter choiceType: The Swift type a choice prints as (its cases must share the choice's raw values).
    public init(choiceType: @escaping @Sendable (TunableDescriptor) -> String? = { _ in nil }) {
        self.choiceType = choiceType
    }

    /// One `static let` per descriptor, in order, with a comment naming its key and, when it differs, its default.
    /// - Parameters:
    ///   - title: The header comment's surface name.
    ///   - rows: Each tunable with its current value and its default.
    /// - Returns: Swift source text.
    public func swiftConstants(title: String, rows: [(descriptor: TunableDescriptor, value: TunableValue, defaultValue: TunableValue)]) -> String {
        var lines = ["// \(title): tuned values. Paste over the defaults, then reset the panel."]
        for row in rows {
            let name = (row.descriptor.codeName ?? row.descriptor.key).split(separator: ".").last.map(String.init) ?? row.descriptor.key
            let (type, literal) = swift(row.value, row.descriptor)
            let note = row.value == row.defaultValue ? "" : ", was \(swift(row.defaultValue, row.descriptor).literal)"
            lines.append("static let \(name): \(type) = \(literal) // \(row.descriptor.key)\(note)")
        }
        return lines.joined(separator: "\n")
    }

    private func swift(_ value: TunableValue, _ descriptor: TunableDescriptor) -> (type: String, literal: String) {
        switch value {
        case .number(let number):
            let unit: TunableUnit? = if case .number(_, _, let unit) = descriptor.kind { unit } else { nil }
            return (unit == .points ? "CGFloat" : "Double", TunableExport.format(number))
        case .bool(let flag): return ("Bool", flag ? "true" : "false")
        case .choice(let raw):
            guard let type = choiceType(descriptor) else { return ("String", "\"\(raw)\"") }
            return (type, "." + raw)
        case .color: return ("TunableColor", TunableExport.swiftLiteral(value))
        case .spring: return ("SpringParameters", TunableExport.swiftLiteral(value))
        }
    }
}
