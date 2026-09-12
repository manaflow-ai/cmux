import CmuxTerminalCore

struct TerminalCapturedLinkForwardRequest: Sendable {
    let links: [TerminalCapturedLink]
    let settings: LinkCaptureSettingsSnapshot
}
