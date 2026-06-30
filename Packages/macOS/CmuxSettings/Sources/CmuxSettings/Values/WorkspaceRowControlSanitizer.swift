import Foundation

/// Normalizes cmux-provided sidebar workspace-row controls before storage or
/// rendering.
public struct WorkspaceRowControlSanitizer: Sendable {
    /// Maximum number of controls a workspace row may expose.
    public let maximumVisibleControls: Int
    /// Controls to use when a stored value does not contain any valid controls.
    public let defaultControls: [WorkspaceRowControlOption]

    /// Creates a sanitizer with the product cap and default close control.
    public init(
        maximumVisibleControls: Int = WorkspaceRowControlOption.maximumVisibleControls,
        defaultControls: [WorkspaceRowControlOption] = WorkspaceRowControlOption.defaultControls
    ) {
        self.maximumVisibleControls = maximumVisibleControls
        self.defaultControls = defaultControls
    }

    /// Returns a duplicate-free, capped list that always includes
    /// ``WorkspaceRowControlOption/close``.
    ///
    /// Unknown raw values are dropped by callers before reaching this method.
    /// The user's order is otherwise preserved, with `close` inserted first only
    /// when it was absent or promoted into the capped result when the cap would
    /// otherwise exclude it.
    public func sanitized(_ controls: [WorkspaceRowControlOption]) -> [WorkspaceRowControlOption] {
        var orderedControls: [WorkspaceRowControlOption] = []
        var seen = Set<WorkspaceRowControlOption>()

        func append(_ option: WorkspaceRowControlOption) {
            guard seen.insert(option).inserted else { return }
            orderedControls.append(option)
        }

        if !controls.contains(.close) {
            append(.close)
        }
        for option in controls {
            append(option)
        }
        if orderedControls.isEmpty {
            for option in defaultControls {
                append(option)
            }
        }
        if !orderedControls.contains(.close) {
            orderedControls.insert(.close, at: 0)
        }

        let limit = max(1, maximumVisibleControls)
        guard orderedControls.count > limit else {
            return orderedControls
        }

        var cappedControls = Array(orderedControls.prefix(limit))
        if !cappedControls.contains(.close) {
            cappedControls[limit - 1] = .close
        }
        return cappedControls
    }

    /// Decodes a raw string array from `cmux.json` / `UserDefaults`, dropping
    /// unknown entries before applying the close-control invariant and cap.
    public func sanitizedRawValues(_ rawValues: [String]) -> [WorkspaceRowControlOption] {
        sanitized(rawValues.compactMap { WorkspaceRowControlOption(rawValue: $0) })
    }
}
