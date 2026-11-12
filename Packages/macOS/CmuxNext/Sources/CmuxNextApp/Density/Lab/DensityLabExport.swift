#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextDesign
import Foundation

/// The Density Lab's harvest text: the `DensityPreset.tokens` switch with the lab's values.
struct DensityLabExport {
    static func swift(_ densities: [DensityTokens]) -> String {
        var lines = ["        switch self {"]
        for density in densities {
            var args = ["id: rawValue", "name: \"\(density.name)\""]
            if density.level != 0 { args.append("level: \(number(density.level))") }
            if density.spacing != 1 { args.append("spacing: \(number(density.spacing))") }
            if let size = density.fontSize { args.append("fontSize: \(number(size))") }
            if !density.tokens.isEmpty {
                let pairs = density.tokens.sorted { $0.key < $1.key }.map { "\"\($0.key)\": \(number($0.value))" }
                args.append("tokens: [\(pairs.joined(separator: ", "))]")
            }
            lines.append("        case .\(density.id): DensityTokens(\(args.joined(separator: ", ")))")
        }
        lines.append("        }")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }
}
#endif
