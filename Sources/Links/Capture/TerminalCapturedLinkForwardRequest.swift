import CmuxTerminalCore

struct TerminalCapturedLinkForwardRequest: Sendable {
    let link: TerminalCapturedLink
    let settings: LinkCaptureSettingsSnapshot
}
