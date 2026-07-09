import Foundation

/// The localized titles, labels, and formats that `CmuxTaskManagerSnapshotDecoder`
/// stamps onto the rows it produces.
///
/// This is the localization seam for the decoder: every user-facing string the
/// decoder emits is carried here as either a resolved label or a `@Sendable`
/// format closure, so the decoder itself never calls `String(localized:)`. The
/// app constructs this value (`CmuxTaskManagerStrings()` resolves each string
/// against the app bundle, which owns the `taskManager.*` keys) and injects it
/// into the decoder. Keeping resolution app-side lets the decoder stay free of
/// the app bundle while still producing fully localized rows; tests can inject a
/// fixed value through the memberwise initializer.
///
/// The format closures preserve the exact original `String(localized:)` /
/// `String(format:)` expressions (including interpolation argument types and
/// specifiers), so the seam is byte-faithful to the former inline calls.
struct CmuxTaskManagerStrings: Sendable {
    /// "Unattributed" — used when a memory group has no attribution.
    let unattributed: String
    /// "Key window" — detail flag on the key window row.
    let keyWindow: String
    /// "Hidden" — detail flag on a non-visible window row.
    let hidden: String
    /// "Selected" — detail flag on a selected workspace/surface row.
    let selected: String
    /// "Pinned" — detail flag on a pinned workspace row.
    let pinned: String
    /// "Unknown tag" — fallback title for a tag with no key.
    let unknownTag: String
    /// "Focused" — detail flag on a focused pane row.
    let focused: String
    /// "Process" — fallback title for a process row with no name or pid.
    let process: String
    /// "WebView" — fallback title for a webview row with no title.
    let webview: String
    /// "1 process" — singular process-count detail.
    let processCountOne: String
    /// "Browser" — surface-type label.
    let surfaceTypeBrowser: String
    /// "Terminal" — surface-type label.
    let surfaceTypeTerminal: String
    /// "Unknown" — surface-type label.
    let surfaceTypeUnknown: String

    /// "Workspace %@" — memory-attribution workspace detail.
    let memoryWorkspace: @Sendable (String) -> String
    /// "Pane %@" — memory-attribution pane detail.
    let memoryPane: @Sendable (String) -> String
    /// "Surface %@" — memory-attribution surface detail.
    let memorySurface: @Sendable (String) -> String
    /// "%lld processes" — plural process-count detail.
    let processCountOther: @Sendable (Int) -> String
    /// "Window \<handle>" — window row title.
    let window: @Sendable (String) -> String
    /// "Pane \<handle>" — pane row title.
    let pane: @Sendable (String) -> String
    /// "PID \<pid>" — pid detail shared by tag/webview/process rows.
    let pid: @Sendable (Int) -> String
    /// "Shared x\<count>" — shared-process detail on a webview row.
    let sharedProcess: @Sendable (Int) -> String
    /// "Process \<pid>" — process row title fallback that has a pid.
    let processWithPID: @Sendable (Int) -> String
}

extension CmuxTaskManagerStrings {
    /// Resolves every label and format against the app bundle via
    /// `String(localized:)`. This is the production constructor used by the app
    /// when wiring a `CmuxTaskManagerSnapshotDecoder`.
    init() {
        self.init(
            unattributed: String(localized: "taskManager.memory.unattributed", defaultValue: "Unattributed"),
            keyWindow: String(localized: "taskManager.row.keyWindow", defaultValue: "Key window"),
            hidden: String(localized: "taskManager.row.hidden", defaultValue: "Hidden"),
            selected: String(localized: "taskManager.row.selected", defaultValue: "Selected"),
            pinned: String(localized: "taskManager.row.pinned", defaultValue: "Pinned"),
            unknownTag: String(localized: "taskManager.row.unknownTag", defaultValue: "Unknown tag"),
            focused: String(localized: "taskManager.row.focused", defaultValue: "Focused"),
            process: String(localized: "taskManager.row.process", defaultValue: "Process"),
            webview: String(localized: "taskManager.row.webview", defaultValue: "WebView"),
            processCountOne: String(localized: "taskManager.aggregate.processCount.one", defaultValue: "1 process"),
            surfaceTypeBrowser: String(localized: "taskManager.row.surfaceType.browser", defaultValue: "Browser"),
            surfaceTypeTerminal: String(localized: "taskManager.row.surfaceType.terminal", defaultValue: "Terminal"),
            surfaceTypeUnknown: String(localized: "taskManager.row.surfaceType.unknown", defaultValue: "Unknown"),
            memoryWorkspace: { workspace in
                String(format: String(
                    localized: "taskManager.memory.workspace",
                    defaultValue: "Workspace %@"
                ), workspace)
            },
            memoryPane: { pane in
                String(format: String(
                    localized: "taskManager.memory.pane",
                    defaultValue: "Pane %@"
                ), pane)
            },
            memorySurface: { surface in
                String(format: String(
                    localized: "taskManager.memory.surface",
                    defaultValue: "Surface %@"
                ), surface)
            },
            processCountOther: { processCount in
                String(format: String(
                    localized: "taskManager.aggregate.processCount.other",
                    defaultValue: "%lld processes"
                ), Int64(processCount))
            },
            window: { handle in
                String(localized: "taskManager.row.window", defaultValue: "Window \(handle)")
            },
            pane: { handle in
                String(localized: "taskManager.row.pane", defaultValue: "Pane \(handle)")
            },
            pid: { pid in
                String(localized: "taskManager.row.pid", defaultValue: "PID \(pid)")
            },
            sharedProcess: { sharedCount in
                String(localized: "taskManager.row.sharedProcess", defaultValue: "Shared x\(sharedCount)")
            },
            processWithPID: { pid in
                String(localized: "taskManager.row.processWithPID", defaultValue: "Process \(pid)")
            }
        )
    }
}
