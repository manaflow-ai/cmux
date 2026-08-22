import CoreGraphics
import Foundation

/// Identifies one on-screen macOS application window that can be mirrored.
struct MacAppWindowDescriptor: Hashable, Identifiable, Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let applicationName: String
    let bundleIdentifier: String?
    let title: String
    let frame: CGRect

    var id: String {
        "\(processID):\(windowID)"
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? applicationName : "\(applicationName) · \(trimmedTitle)"
    }
}
