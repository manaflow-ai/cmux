import CmuxNextWindowRules

/// What the Rust Computer Use step rules read and answer (`onboarding_steps_computer_use`): the
/// app's types as cmux-window-rules `onboarding_steps` names them. No rule lives here.
extension ComputerUseStepModel {
    /// The window's state between events, as Rust keeps it.
    nonisolated struct State: Codable, Equatable, Sendable {
        var grants = Grants(ComputerUsePermissions.none)
        var received = false
        var helping: String?
        var unavailable = false
        var allowedHere: [String] = []
        var pendingAllow: String?
        var source = false
        var helper = false
    }

    nonisolated struct Grants: Codable, Equatable, Sendable {
        var accessibility: Bool, screenRecording: Bool, helperVersionMismatch: Bool
        var isOff: Bool, helperFailed: Bool, isReading: Bool

        init(_ permissions: ComputerUsePermissions) {
            accessibility = permissions.accessibility
            screenRecording = permissions.screenRecording
            helperVersionMismatch = permissions.helperVersionMismatch
            isOff = permissions.isOff
            helperFailed = permissions.helperFailed
            isReading = permissions.isReading
        }

        var permissions: ComputerUsePermissions {
            ComputerUsePermissions(accessibility: accessibility, screenRecording: screenRecording,
                                   helperVersionMismatch: helperVersionMismatch, isOff: isOff,
                                   helperFailed: helperFailed, isReading: isReading)
        }
    }

    /// One event in the window (Rust `Event`).
    nonisolated struct Event: Encodable, Sendable {
        var kind: String
        var pane: String?
        var grants: Grants?

        static func grants(_ permissions: ComputerUsePermissions) -> Event {
            Event(kind: "grants", grants: Grants(permissions))
        }

        static func allow(_ pane: ComputerUsePermissionPane) -> Event { Event(kind: "allow", pane: pane.rawValue) }
        static func allowOnceKnown(_ pane: ComputerUsePermissionPane) -> Event {
            Event(kind: "allowOnceKnown", pane: pane.rawValue)
        }

        static let allowNext = Event(kind: "allowNext")
        static let restart = Event(kind: "restart")
        static let dismissHelper = Event(kind: "dismissHelper")
        static let stop = Event(kind: "stop")
    }

    /// What the window shows from its state (Rust `View`).
    nonisolated struct View: Decodable, Equatable, Sendable {
        nonisolated struct Row: Decodable, Equatable, Sendable { var pane: String, control: String }
        var nextPane: String?
        var primary: String?
        var allGranted = false
        var finished = false
        var confirmsCapture = false
        var rows: [Row] = []
        var note: String?

        /// A row's trailing control: `hidden`, `done`, `allowPrimary` or `allow`.
        func control(_ pane: ComputerUsePermissionPane) -> String {
            rows.first { $0.pane == pane.rawValue }?.control ?? "hidden"
        }
    }

    /// An event's answer: the new state, the effects in order, the view (Rust `Outcome`).
    nonisolated struct Outcome: Decodable, Sendable {
        var state: State
        var comeback: Bool
        var enable: Bool
        var openSettings: String?
        var restart: Bool
        var timer: String?
        var accepted: Bool
        var view: View
    }
}
