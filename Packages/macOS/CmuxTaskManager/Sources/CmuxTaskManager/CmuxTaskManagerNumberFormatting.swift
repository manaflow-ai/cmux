public import Foundation

extension Double {
    /// The CPU percentage rendered for a Task Manager cell, clamped at zero
    /// and shown to one decimal place (e.g. `12.3%`). Reads as a property on
    /// the value being formatted.
    public var taskManagerCPUString: String {
        String(format: "%.1f%%", Swift.max(0, self))
    }
}

extension Int64 {
    /// A byte count rendered for a Task Manager cell using binary (1024)
    /// units. Bytes show as a whole number; KB and larger show one decimal
    /// place (e.g. `512 B`, `1.5 MB`). Reads as a property on the value being
    /// formatted.
    public var taskManagerByteString: String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(Swift.max(0, self))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}
