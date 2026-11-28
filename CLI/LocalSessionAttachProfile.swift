import Foundation

/// Where a local persistent session's cmux client surface should attach.
struct LocalSessionAttachRequest {
    var workspace: String?
    var surface: String?
    var pane: String?
    var window: String?
    var focus: Bool?
    var newClient = false

    var hasTarget: Bool {
        workspace != nil || surface != nil || pane != nil || window != nil || focus != nil
    }
}

/// What differs between the multiplexers behind cmux's local persistent
/// session profiles when a cmux surface attaches as a client.
struct LocalSessionAttachProfile {
    enum Target {
        case pane
        case surface
    }

    /// Reported as `mode` in attach output.
    let mode: String
    /// Title of a workspace created for a session, before the session name.
    let workspaceTitlePrefix: String
    /// Process name that proves a surface still runs a live client.
    let clientProcessName: String
    let workspaceNotFound: () -> String
    let workspaceRequiredForTarget: () -> String
    let livenessUnavailable: () -> String
    let targetNotFound: (_ target: Target, _ raw: String) -> String
    let workspaceCreateFailed: (_ sessionName: String) -> String
    let attached: (_ sessionName: String, _ surfaceID: String?) -> String

    static var localTmux: LocalSessionAttachProfile {
        LocalSessionAttachProfile(
            mode: "local-tmux",
            workspaceTitlePrefix: "tmux:",
            clientProcessName: "tmux",
            workspaceNotFound: {
                String(localized: "cli.localTmux.error.workspaceNotFound", defaultValue: "local-tmux workspace target was not found")
            },
            workspaceRequiredForTarget: {
                String(localized: "cli.localTmux.error.workspaceRequiredForTarget", defaultValue: "local-tmux pane or surface targets require a workspace")
            },
            livenessUnavailable: {
                String(localized: "cli.localTmux.error.livenessUnavailable", defaultValue: "local-tmux could not verify the existing surface; no new client was created")
            },
            targetNotFound: { target, raw in
                let label = switch target {
                case .pane: String(localized: "cli.localTmux.target.pane", defaultValue: "pane")
                case .surface: String(localized: "cli.localTmux.target.surface", defaultValue: "surface")
                }
                return String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.targetNotFound", defaultValue: "local-tmux could not resolve %@ target %@"),
                    label,
                    raw
                )
            },
            workspaceCreateFailed: { sessionName in
                String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.error.workspaceCreateFailed", defaultValue: "local-tmux could not create a workspace for %@"),
                    sessionName
                )
            },
            attached: { sessionName, surfaceID in
                String.localizedStringWithFormat(
                    String(localized: "cli.localTmux.output.attached", defaultValue: "OK session=%@ surface=%@ mode=local-tmux"),
                    sessionName,
                    surfaceID ?? String(localized: "cli.localTmux.state.unknown", defaultValue: "unknown")
                )
            }
        )
    }

    static var localZellij: LocalSessionAttachProfile {
        LocalSessionAttachProfile(
            mode: "local-zellij",
            workspaceTitlePrefix: "zellij:",
            clientProcessName: "zellij",
            workspaceNotFound: {
                String(localized: "cli.localZellij.error.workspaceNotFound", defaultValue: "local-zellij workspace target was not found")
            },
            workspaceRequiredForTarget: {
                String(localized: "cli.localZellij.error.workspaceRequiredForTarget", defaultValue: "local-zellij pane or surface targets require a workspace")
            },
            livenessUnavailable: {
                String(localized: "cli.localZellij.error.livenessUnavailable", defaultValue: "local-zellij could not verify the existing surface; no new client was created")
            },
            targetNotFound: { target, raw in
                let label = switch target {
                case .pane: String(localized: "cli.localZellij.target.pane", defaultValue: "pane")
                case .surface: String(localized: "cli.localZellij.target.surface", defaultValue: "surface")
                }
                return String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.error.targetNotFound", defaultValue: "local-zellij could not resolve %@ target %@"),
                    label,
                    raw
                )
            },
            workspaceCreateFailed: { sessionName in
                String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.error.workspaceCreateFailed", defaultValue: "local-zellij could not create a workspace for %@"),
                    sessionName
                )
            },
            attached: { sessionName, surfaceID in
                String.localizedStringWithFormat(
                    String(localized: "cli.localZellij.output.attached", defaultValue: "OK session=%@ surface=%@ mode=local-zellij"),
                    sessionName,
                    surfaceID ?? String(localized: "cli.localZellij.state.unknown", defaultValue: "unknown")
                )
            }
        )
    }
}
