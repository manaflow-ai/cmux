import Foundation
import Combine

/// Type of panel content
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
}

enum FocusFlashCurve: Equatable {
    case easeIn
    case easeOut
}

struct FocusFlashSegment: Equatable {
    let delay: TimeInterval
    let duration: TimeInterval
    let targetOpacity: Double
    let curve: FocusFlashCurve
}

enum FocusFlashPattern {
    static let values: [Double] = [0, 1, 0, 1, 0]
    static let keyTimes: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let duration: TimeInterval = 0.9
    static let curves: [FocusFlashCurve] = [.easeOut, .easeIn, .easeOut, .easeIn]
    static let ringInset: Double = 6
    static let ringCornerRadius: Double = 10

    static var segments: [FocusFlashSegment] {
        let stepCount = min(curves.count, values.count - 1, keyTimes.count - 1)
        return (0..<stepCount).map { index in
            let startTime = keyTimes[index]
            let endTime = keyTimes[index + 1]
            return FocusFlashSegment(
                delay: startTime * duration,
                duration: (endTime - startTime) * duration,
                targetOpacity: values[index + 1],
                curve: curves[index]
            )
        }
    }
}

/// Protocol for all panel types (terminal, browser, etc.)
@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    /// Unique identifier for this panel
    var id: UUID { get }

    /// The type of panel
    var panelType: PanelType { get }

    /// Display title shown in tab bar
    var displayTitle: String { get }

    /// Optional SF Symbol icon name for the tab
    var displayIcon: String? { get }

    /// Whether the panel has unsaved changes
    var isDirty: Bool { get }

    /// Close the panel and clean up resources
    func close()

    /// Focus the panel for input
    func focus()

    /// Unfocus the panel
    func unfocus()

    /// Trigger a focus flash animation for this panel.
    func triggerFlash()
}

/// Extension providing default implementations
extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }
}
