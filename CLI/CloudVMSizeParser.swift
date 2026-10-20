import Foundation

/// Parses the user-facing `--size` spelling without embedding a server image
/// ladder in the CLI. The control plane validates whether the resulting
/// memory capability is currently available.
struct CloudVMSizeParser {
    func parse(_ raw: String) -> Int? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let suffix: String?
        if normalized.hasSuffix("gib") { suffix = "gib" }
        else if normalized.hasSuffix("gb") { suffix = "gb" }
        else if normalized.hasSuffix("g") { suffix = "g" }
        else if normalized.hasSuffix("mib") { suffix = "mib" }
        else if normalized.hasSuffix("mb") { suffix = "mb" }
        else { suffix = nil }
        let number = if let suffix { String(normalized.dropLast(suffix.count)) } else { normalized }
        guard let value = Int(number), value > 0 else { return nil }
        if suffix == nil || suffix == "mb" || suffix == "mib" {
            return value >= 512 ? value : nil
        }
        return value.multipliedReportingOverflow(by: 1024).overflow ? nil : value * 1024
    }
}
