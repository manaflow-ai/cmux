public import Foundation

/// A macOS grant an agent can ask the person for through cmux
/// (plans/cmux-next/agent-permissions-DESIGN.md section 2).
///
/// The raw value is the wire name the socket, the CLI and MCP use.
public nonisolated enum PermissionKind: String, Sendable, CaseIterable, Codable {
    /// Read files macOS protects (Mail, Messages, Safari, other apps' data).
    case fullDiskAccess = "full_disk_access"
    /// Click and type in other apps (held by the cmux Computer Use helper).
    case accessibility
    /// See other apps' windows (held by the cmux Computer Use helper).
    case screenRecording = "screen_recording"
    /// Send Apple Events to one other app (`target` names its bundle id).
    case automation
    /// Use the camera.
    case camera
    /// Use the microphone.
    case microphone
    /// Computer use: Accessibility and Screen Recording on the helper, one after the other.
    case computerUse = "computer_use"

    /// The grants this kind needs, in the order the guide asks for them.
    public var grants: [PermissionKind] {
        self == .computerUse ? [.accessibility, .screenRecording] : [self]
    }

    /// Whether the guide shows the app tile to drag into the list. Camera,
    /// microphone and automation have no list to drag into: macOS asks once
    /// after Continue.
    public var usesDragHelper: Bool {
        switch self {
        case .fullDiskAccess, .accessibility, .screenRecording, .computerUse: true
        case .automation, .camera, .microphone: false
        }
    }

    /// Whether the grant belongs to the cmux Computer Use helper, not to cmux.
    public var heldByComputerUseHelper: Bool {
        switch self {
        case .accessibility, .screenRecording, .computerUse: true
        case .fullDiskAccess, .automation, .camera, .microphone: false
        }
    }

    /// The Privacy & Security anchor of the list in System Settings (the
    /// first grant's list for computer use).
    public var settingsAnchor: String {
        switch self {
        case .fullDiskAccess: "Privacy_AllFiles"
        case .accessibility, .computerUse: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .automation: "Privacy_Automation"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        }
    }

    /// The System Settings URL that opens the list.
    public var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
    }

    /// Words a person uses when they ask for work that needs this grant
    /// (stems, lowercase). ``PermissionReasonCheck`` reads them.
    var vocabulary: Set<String> {
        switch self {
        case .fullDiskAccess:
            ["file", "folder", "disk", "mail", "email", "messag", "imessag", "safari", "librar", "import", "backup",
             "databas", "note", "photo", "calendar", "contact", "histor", "bookmark", "document", "download"]
        case .accessibility, .computerUse:
            ["click", "type", "app", "control", "press", "button", "menu", "window", "fill", "form", "drive",
             "automat", "export", "screen", "drag"]
        case .screenRecording:
            ["screen", "screenshot", "see", "look", "window", "record", "captur", "watch", "show", "video", "share"]
        case .automation:
            ["script", "applescript", "automat", "control", "app", "music", "finder", "mail", "safari", "note", "remind", "calendar"]
        case .camera:
            ["camera", "photo", "video", "pictur", "selfi", "scan", "qr", "call", "meet"]
        case .microphone:
            ["microphon", "mic", "voic", "speak", "talk", "dictat", "record", "audio", "call", "transcrib", "listen"]
        }
    }
}
