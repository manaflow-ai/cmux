import Foundation

/// Argument definitions shared by catalog actions. Titles live in
/// Localizable.xcstrings under `argument.<name>` and `argument.value.<value>`.
nonisolated enum CatalogArgument {
    static var workspaceWorkspace: ActionArgument {
        ActionArgument(name: "workspace", title: String(localized: "argument.workspace", defaultValue: "Workspace", bundle: .module), kind: .target(.workspace))
    }

    static var processString: ActionArgument {
        ActionArgument(name: "process", title: String(localized: "argument.process", defaultValue: "Process", bundle: .module), kind: .string)
    }

    static var indexNumber: ActionArgument {
        ActionArgument(name: "index", title: String(localized: "argument.index", defaultValue: "Number", bundle: .module), kind: .int(1...9))
    }

    static var windowWindow: ActionArgument {
        ActionArgument(name: "window", title: String(localized: "argument.window", defaultValue: "Window", bundle: .module), kind: .target(.window))
    }

    /// Where a screenshot goes: an absolute PNG path, `-` for the image
    /// inline in the result (base64), or omitted for a file in the
    /// temporary directory (ScreenshotHandlers).
    static var screenshotOut: ActionArgument {
        ActionArgument(name: "out", title: String(localized: "argument.out", defaultValue: "Output File", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// A cmux Cloud team of the signed-in account, by id (Team Picker): the palette lists the teams
    /// and marks the current one.
    static var cloudTeam: ActionArgument {
        ActionArgument(name: "team", title: String(localized: "argument.team", defaultValue: "Team", bundle: .module), kind: .string,
                       suggestions: ActionSuggestions(source: ActionSuggestions.cloudTeams, pinned: []))
    }

    static var nameString: ActionArgument {
        ActionArgument(name: "name", title: String(localized: "argument.name", defaultValue: "Name", bundle: .module), kind: .string)
    }

    /// Tabs by id, comma-separated (`--arg tabs=<id>,<id>`): a tab action's tabs for the CLI and
    /// MCP, which have no strip selection. The palette never asks for it.
    static var tabsList: ActionArgument {
        ActionArgument(name: "tabs", title: String(localized: "argument.tabs", defaultValue: "Tabs", bundle: .module), kind: .string, isRequired: false)
    }

    static var descriptionString: ActionArgument {
        ActionArgument(name: "description", title: String(localized: "argument.description", defaultValue: "Description", bundle: .module), kind: .string)
    }

    static var statusChoice: ActionArgument {
        ActionArgument(name: "status", title: String(localized: "argument.status", defaultValue: "Status", bundle: .module), kind: .enumeration([choice("auto"), choice("todo"), choice("working"), choice("needs-attention"), choice("review"), choice("done")]))
    }

    /// A workspace checklist item (`chk_…`); without one a checklist action acts on the current
    /// item (the first in progress, else the first to do).
    static var checklistItem: ActionArgument {
        ActionArgument(name: "item", title: String(localized: "argument.checklistItem", defaultValue: "Checklist Item", bundle: .module),
                       kind: .string, isRequired: false)
    }

    static var textString: ActionArgument {
        ActionArgument(name: "text", title: String(localized: "argument.text", defaultValue: "Text", bundle: .module), kind: .string)
    }

    static var colorChoice: ActionArgument {
        ActionArgument(name: "color", title: String(localized: "argument.color", defaultValue: "Color", bundle: .module), kind: .enumeration([choice("grey"), choice("blue"), choice("red"), choice("yellow"), choice("green"), choice("pink"), choice("purple"), choice("cyan"), choice("orange")]))
    }

    static var templateString: ActionArgument {
        ActionArgument(name: "template", title: String(localized: "argument.template", defaultValue: "Template", bundle: .module), kind: .string,
                       suggestions: ActionSuggestions(source: ActionSuggestions.layoutTemplates, pinned: []))
    }

    static var groupWorkspaceGroup: ActionArgument {
        ActionArgument(name: "group", title: String(localized: "argument.group", defaultValue: "Group", bundle: .module), kind: .target(.workspaceGroup))
    }

    static var panePane: ActionArgument {
        ActionArgument(name: "pane", title: String(localized: "argument.pane", defaultValue: "Pane", bundle: .module), kind: .target(.pane))
    }

    /// A recently closed item (`closed_…`); Recently Closed lists them.
    static var closedItem: ActionArgument {
        ActionArgument(name: "closed", title: String(localized: "argument.closed", defaultValue: "Closed Item", bundle: .module),
                       kind: .string, isRequired: false)
    }

    static var groupTabGroup: ActionArgument {
        ActionArgument(name: "group", title: String(localized: "argument.group", defaultValue: "Group", bundle: .module), kind: .target(.tabGroup))
    }

    static var groupScreenGroup: ActionArgument {
        ActionArgument(name: "group", title: String(localized: "argument.group", defaultValue: "Group", bundle: .module), kind: .target(.screenGroup))
    }

    /// A saved group id.
    static var savedString: ActionArgument {
        ActionArgument(name: "saved", title: String(localized: "argument.savedGroup", defaultValue: "Saved Group", table: "ScreenActions", bundle: .module), kind: .string)
    }

    static var directionChoice: ActionArgument {
        ActionArgument(name: "direction", title: String(localized: "argument.direction", defaultValue: "Direction", bundle: .module), kind: .enumeration([choice("right"), choice("down"), choice("left"), choice("up")]))
    }

    /// A docked column's viewport edge (plans/cmux-next/dock-column.md).
    /// Top and bottom are edge docks (layout-model.md, edge-docks-v1).
    static var edgeChoice: ActionArgument {
        ActionArgument(name: "edge", title: String(localized: "argument.edge", defaultValue: "Edge", bundle: .module),
                       kind: .enumeration([choice("right"), choice("left"), choice("top"), choice("bottom")]))
    }

    /// Docked (the strip makes room) or overlay (floats over the strip).
    static var dockModeChoice: ActionArgument {
        ActionArgument(name: "mode", title: String(localized: "argument.dockMode", defaultValue: "Mode", bundle: .module),
                       kind: .enumeration([choice("docked"), choice("overlay")]))
    }

    static var commandString: ActionArgument {
        ActionArgument(name: "command", title: String(localized: "argument.command", defaultValue: "Command", bundle: .module), kind: .string)
    }

    static var pathString: ActionArgument {
        ActionArgument(name: "path", title: String(localized: "argument.path", defaultValue: "Path", bundle: .module), kind: .string)
    }

    /// A file to open; without one the action asks with the cmux picker.
    static var optionalPathString: ActionArgument {
        ActionArgument(name: "path", title: String(localized: "argument.path", defaultValue: "Path", bundle: .module), kind: .string,
                       isRequired: false)
    }

    /// `file open --as-text`: a page cmux renders (HTML, SVG, Markdown) opens as its source in the
    /// code editor (Open as Text); other files open as they always do.
    static var asTextBool: ActionArgument {
        ActionArgument(name: "asText", title: String(localized: "argument.asText", defaultValue: "As Text", bundle: .module),
                       kind: .bool, isRequired: false)
    }

    /// `cloud new-terminal-on-machine --workspace <id>`: a workspace on the Cloud machine's own
    /// daemon (the `workspace_id` an earlier run answered). Plain text: `.target(.workspace)`
    /// resolves this Mac's workspaces, not a Cloud machine's.
    static var cloudWorkspaceString: ActionArgument {
        ActionArgument(name: "workspace", title: String(localized: "argument.workspace", defaultValue: "Workspace", bundle: .module),
                       kind: .string, isRequired: false)
    }

    static var contentsString: ActionArgument {
        ActionArgument(name: "contents", title: String(localized: "argument.contents", defaultValue: "Contents", bundle: .module), kind: .string)
    }

    static var publicKeyString: ActionArgument {
        ActionArgument(name: "publicKey", title: String(localized: "argument.publicKey", defaultValue: "SSH Public Key", bundle: .module), kind: .string)
    }

    static var appString: ActionArgument {
        ActionArgument(name: "app", title: String(localized: "argument.app", defaultValue: "App", bundle: .module), kind: .string)
    }

    static var themeChoice: ActionArgument {
        ActionArgument(name: "theme", title: String(localized: "argument.theme", defaultValue: "Theme", bundle: .module), kind: .enumeration([choice("system"), choice("light"), choice("dark")]))
    }

    static var snapshotString: ActionArgument {
        ActionArgument(name: "snapshot", title: String(localized: "argument.snapshot", defaultValue: "Snapshot", bundle: .module), kind: .string)
    }

    static var portInt: ActionArgument {
        ActionArgument(name: "port", title: String(localized: "argument.port", defaultValue: "Port", bundle: .module), kind: .int(1...65535))
    }

    /// `cloud provision-api --name <name>`: what the new API key is called; "API key" without one.
    static var apiKeyNameString: ActionArgument {
        ActionArgument(name: "name", title: String(localized: "argument.name", defaultValue: "Name", bundle: .module), kind: .string,
                       isRequired: false)
    }

    /// `cloud api-key-revoke --key <id>`: the API key id `cloud api-key-list` answers.
    static var apiKeyString: ActionArgument {
        ActionArgument(name: "key", title: String(localized: "argument.apiKey", defaultValue: "API Key", bundle: .module), kind: .string)
    }

    static var sizeChoice: ActionArgument {
        ActionArgument(name: "size", title: String(localized: "argument.size", defaultValue: "Size", bundle: .module), kind: .enumeration([choice("small"), choice("medium"), choice("large"), choice("xlarge")]))
    }

    /// `cloud resize-machine --disk GIB`: the disk's new size in whole GiB (4 GiB steps up to 256, grow-only).
    static var diskGiBInt: ActionArgument {
        ActionArgument(name: "disk", title: String(localized: "argument.diskGiB", defaultValue: "Disk (GiB)", bundle: .module),
                       kind: .int(4...256), isRequired: false)
    }

    /// `cloud enroll-machine --ssh-key FILE`: this Mac's ssh public key (default `~/.ssh/id_ed25519.pub`).
    static var sshKeyString: ActionArgument {
        ActionArgument(name: "sshKey", title: String(localized: "argument.sshKey", defaultValue: "SSH Public Key", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// `cloud new-machine --size small|medium|large|xlarge`: plain text, not a choice, so New Cloud
    /// Machine stays one menu item and one palette row (a choice argument becomes a submenu).
    static var newMachineSizeString: ActionArgument {
        ActionArgument(name: "size", title: String(localized: "argument.size", defaultValue: "Size", bundle: .module), kind: .string, isRequired: false)
    }

    /// `cloud new-machine --persistent`: the new machine's idle auto-pause is Off from its create.
    static var persistentBool: ActionArgument {
        ActionArgument(name: "persistent", title: String(localized: "argument.persistent", defaultValue: "Persistent", bundle: .module),
                       kind: .bool, isRequired: false)
    }

    /// `cloud new-machine --bootstrap none|lane` (with `--bootstrap-script FILE`): the setup the
    /// new machine runs; `lane` also gives it its lane host name (leo-workspace machines/lane-vms.md).
    static var bootstrapString: ActionArgument {
        ActionArgument(name: "bootstrap", title: String(localized: "argument.bootstrap", defaultValue: "Bootstrap", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// `--machine-config FILE`: a `.cmux/machine.toml` on this Mac (CloudMachineConfig).
    static var machineConfigString: ActionArgument {
        ActionArgument(name: "machineConfig", title: String(localized: "argument.machineConfig", defaultValue: "Machine Config", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// `cloud new-machine --repo OWNER/NAME[@REF]`: the GitHub repository the machine clones.
    static var repoString: ActionArgument {
        ActionArgument(name: "repo", title: String(localized: "argument.repo", defaultValue: "Repository", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// The bootstrap script file on this Mac (the CLI makes a relative path absolute).
    static var bootstrapScriptString: ActionArgument {
        ActionArgument(name: "bootstrapScript", title: String(localized: "argument.bootstrapScript", defaultValue: "Bootstrap Script", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// `cloud deliver-secrets --repo OWNER/NAME`: whose repo-scoped secrets the machine gets.
    static var secretRepoString: ActionArgument {
        ActionArgument(name: "repo", title: String(localized: "argument.secretRepo", defaultValue: "Repository", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// `cloud deliver-secrets --names A,B`: the secret names an own machine (SSH or an acpmux peer) gets;
    /// a Cloud machine's come from its machine config.
    static var secretNamesString: ActionArgument {
        ActionArgument(name: "names", title: String(localized: "argument.secretNames", defaultValue: "Secret Names", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// The idle auto-pause choice (`cloudSetIdlePause`): Off, or the minutes
    /// of idle after which cmux Cloud pauses the machine. The server
    /// (`web/services/vms/idlePause.ts`) takes exactly these values.
    static var idlePauseChoice: ActionArgument {
        ActionArgument(name: "minutes", title: String(localized: "argument.idlePause", defaultValue: "Pause When Idle", bundle: .module), kind: .enumeration([
            ActionEnumCase(value: "off", title: String(localized: "argument.value.idlePauseOff", defaultValue: "Off", bundle: .module)),
            ActionEnumCase(value: "15", title: String(localized: "argument.value.idlePause15", defaultValue: "After 15 Minutes", bundle: .module)),
            ActionEnumCase(value: "30", title: String(localized: "argument.value.idlePause30", defaultValue: "After 30 Minutes", bundle: .module)),
            ActionEnumCase(value: "60", title: String(localized: "argument.value.idlePause60", defaultValue: "After 1 Hour", bundle: .module)),
            ActionEnumCase(value: "120", title: String(localized: "argument.value.idlePause120", defaultValue: "After 2 Hours", bundle: .module)),
        ]))
    }

    static var settingString: ActionArgument {
        ActionArgument(name: "setting", title: String(localized: "argument.setting", defaultValue: "Setting", bundle: .module), kind: .string)
    }

    static var cwdString: ActionArgument {
        ActionArgument(name: "cwd", title: String(localized: "argument.cwd", defaultValue: "Working Directory", bundle: .module), kind: .string)
    }

    static var envString: ActionArgument {
        ActionArgument(name: "env", title: String(localized: "argument.env", defaultValue: "Environment (JSON)", bundle: .module), kind: .string)
    }

    static var focusBool: ActionArgument {
        ActionArgument(name: "focus", title: String(localized: "argument.focus", defaultValue: "Focus", bundle: .module), kind: .bool)
    }

    static var keepBool: ActionArgument {
        ActionArgument(name: "keep", title: String(localized: "argument.keep", defaultValue: "Keep After Close", bundle: .module), kind: .bool)
    }

    /// Pin/Unpin's state: true pins, false unpins; left out, the action toggles.
    static var pinnedBool: ActionArgument {
        ActionArgument(name: "pinned", title: String(localized: "argument.pinned", defaultValue: "Pinned", bundle: .module), kind: .bool,
                       isRequired: false)
    }

    /// `cloud share-machine --teammate USER_ID`: the teammate whose chats on the machine change.
    static var teammateString: ActionArgument {
        ActionArgument(name: "teammate", title: String(localized: "argument.teammate", defaultValue: "Teammate", bundle: .module),
                       kind: .string, isRequired: false)
    }

    /// `cloud share-machine --teammate USER_ID --revoke`: take the teammate's share back.
    static var revokeBool: ActionArgument {
        ActionArgument(name: "revoke", title: String(localized: "argument.revoke", defaultValue: "Revoke", bundle: .module),
                       kind: .bool, isRequired: false)
    }

    static var onBool: ActionArgument {
        ActionArgument(name: "on", title: String(localized: "argument.on", defaultValue: "On", bundle: .module), kind: .bool)
    }

    /// Base keymap presets (`ShortcutKeymapPreset` raw values).
    static var keymapChoice: ActionArgument {
        ActionArgument(name: "keymap", title: String(localized: "argument.keymap", defaultValue: "Keymap", bundle: .module), kind: .enumeration([
            ActionEnumCase(value: "cmux", title: String(localized: "argument.value.keymap.cmux", defaultValue: "cmux (Default)", bundle: .module)),
            ActionEnumCase(value: "iterm2", title: String(localized: "argument.value.keymap.iterm2", defaultValue: "iTerm2", bundle: .module)),
            ActionEnumCase(value: "terminal", title: String(localized: "argument.value.keymap.terminal", defaultValue: "Terminal.app", bundle: .module)),
            ActionEnumCase(value: "tmux", title: String(localized: "argument.value.keymap.tmux", defaultValue: "Prefix chords (Ctrl-B)", bundle: .module)),
        ]))
    }

    static var channelChoice: ActionArgument {
        ActionArgument(name: "channel", title: String(localized: "argument.channel", defaultValue: "Channel", bundle: .module), kind: .enumeration([choice("stable"), choice("nightly")]))
    }

    static var topicString: ActionArgument {
        ActionArgument(name: "topic", title: String(localized: "argument.topic", defaultValue: "Topic", bundle: .module), kind: .string)
    }

    /// Optional page to open (`openBrowser`).
    /// Optional palette scope id (`palette.open`): `tabs`, `workspaces`,
    /// `app:<id>#<scope>`; the full palette when absent.
    static var scopeString: ActionArgument {
        ActionArgument(name: "scope", title: String(localized: "argument.scope", defaultValue: "Scope", bundle: .module), kind: .string,
                       isRequired: false)
    }

    /// Optional search text (`tab.search`): the page opens with it typed.
    static var queryString: ActionArgument {
        ActionArgument(name: "query", title: String(localized: "argument.query", defaultValue: "Search", bundle: .module), kind: .string,
                       isRequired: false)
    }

    /// Optional browser profile (`openBrowser`): "agent" for the clean agent
    /// profile, or an existing profile id (plans/cmux-next/passwords.md, 3.4).
    static var browserProfileString: ActionArgument {
        ActionArgument(name: "profile", title: String(localized: "argument.browserProfile", defaultValue: "Browser Profile", bundle: .module),
                       kind: .string, isRequired: false)
    }

    static var urlString: ActionArgument {
        ActionArgument(name: "url", title: String(localized: "argument.url", defaultValue: "URL", bundle: .module), kind: .string, isRequired: false)
    }

    /// Optional browser engine (`openBrowser`). Without it the tab uses
    /// `browser.defaultEngine` (Chromium unless set to WebKit).
    static var engineChoice: ActionArgument {
        ActionArgument(name: "engine", title: String(localized: "argument.engine", defaultValue: "Engine", bundle: .module),
                       kind: .enumeration([choice("webkit"), choice("cef")]), isRequired: false)
    }

    /// Where `file.open` opens a file: a tab in the pane, or the text editor.
    /// Without it, a tab.
    static var whereChoice: ActionArgument {
        ActionArgument(name: "where", title: String(localized: "argument.where", defaultValue: "Open In", bundle: .module),
                       kind: .enumeration([choice("tab"), choice("editor")]), isRequired: false)
    }

    /// Optional `confirm` flag every destructive action takes.
    static var confirmBool: ActionArgument {
        ActionArgument(name: ActionArgument.confirmName, title: String(localized: "argument.confirm", defaultValue: "Confirm", bundle: .module),
                       kind: .bool, isRequired: false)
    }

    private static func choice(_ value: String) -> ActionEnumCase {
        ActionEnumCase(value: value, title: choiceTitle(value))
    }

    private static func choiceTitle(_ value: String) -> String {
        switch value {
        case "grey": String(localized: "argument.value.grey", defaultValue: "Grey", bundle: .module)
        case "docked": String(localized: "argument.value.docked", defaultValue: "Docked", bundle: .module)
        // UI name "Floating"; the value stays `overlay` on the wire and in cmux.json.
        case "overlay": String(localized: "argument.value.overlay", defaultValue: "Floating", bundle: .module)
        case "blue": String(localized: "argument.value.blue", defaultValue: "Blue", bundle: .module)
        case "red": String(localized: "argument.value.red", defaultValue: "Red", bundle: .module)
        case "yellow": String(localized: "argument.value.yellow", defaultValue: "Yellow", bundle: .module)
        case "green": String(localized: "argument.value.green", defaultValue: "Green", bundle: .module)
        case "pink": String(localized: "argument.value.pink", defaultValue: "Pink", bundle: .module)
        case "purple": String(localized: "argument.value.purple", defaultValue: "Purple", bundle: .module)
        case "cyan": String(localized: "argument.value.cyan", defaultValue: "Cyan", bundle: .module)
        case "orange": String(localized: "argument.value.orange", defaultValue: "Orange", bundle: .module)
        case "webkit": String(localized: "argument.value.webkit", defaultValue: "WebKit", bundle: .module)
        case "cef": String(localized: "argument.value.cef", defaultValue: "Chromium", bundle: .module)
        case "auto": String(localized: "argument.value.auto", defaultValue: "Automatic", bundle: .module)
        case "todo": String(localized: "argument.value.todo", defaultValue: "To Do", bundle: .module)
        case "working": String(localized: "argument.value.working", defaultValue: "Working", bundle: .module)
        case "needs-attention": String(localized: "argument.value.needsAttention", defaultValue: "Needs Attention", bundle: .module)
        case "review": String(localized: "argument.value.review", defaultValue: "In Review", bundle: .module)
        case "done": String(localized: "argument.value.done", defaultValue: "Done", bundle: .module)
        case "system": String(localized: "argument.value.system", defaultValue: "System", bundle: .module)
        case "light": String(localized: "argument.value.light", defaultValue: "Light", bundle: .module)
        case "dark": String(localized: "argument.value.dark", defaultValue: "Dark", bundle: .module)
        case "small": String(localized: "argument.value.small", defaultValue: "Small", bundle: .module)
        case "medium": String(localized: "argument.value.medium", defaultValue: "Medium", bundle: .module)
        case "large": String(localized: "argument.value.large", defaultValue: "Large", bundle: .module)
        case "xlarge": String(localized: "argument.value.xlarge", defaultValue: "Extra Large", bundle: .module)
        case "stable": String(localized: "argument.value.stable", defaultValue: "Stable", bundle: .module)
        case "nightly": String(localized: "argument.value.nightly", defaultValue: "Nightly", bundle: .module)
        case "right": String(localized: "argument.value.right", defaultValue: "Right", bundle: .module)
        case "down": String(localized: "argument.value.down", defaultValue: "Down", bundle: .module)
        case "left": String(localized: "argument.value.left", defaultValue: "Left", bundle: .module)
        case "up": String(localized: "argument.value.up", defaultValue: "Up", bundle: .module)
        case "tab": String(localized: "argument.value.tab", defaultValue: "Tab", bundle: .module)
        case "editor": String(localized: "argument.value.editor", defaultValue: "Editor", bundle: .module)
        default: value
        }
    }

    /// A fit for `browserFit`: an aspect ratio W:H ("16:10") or a layout width in CSS px ("1440"),
    /// or `off`. The pinned values are the fit bar's; any other value goes to the daemon as typed.
    static var fitChoice: ActionArgument {
        let pinned = ["16:9", "16:10", "4:3", "21:9"].map { ActionEnumCase(value: $0, title: $0) }
            + [1280, 1440, 1920].map { ActionEnumCase(value: String($0), title: String(localized: "argument.value.fitWidth", defaultValue: "\($0) px", bundle: .module)) }
            + [ActionEnumCase(value: "off", title: String(localized: "argument.value.fitOff", defaultValue: "Turn Off", bundle: .module))]
        return ActionArgument(name: "fit", title: String(localized: "argument.fit", defaultValue: "Aspect Ratio or Width", bundle: .module), kind: .string,
                              suggestions: ActionSuggestions(source: "browserFit", pinned: pinned))
    }

    /// How Open Desktop shows a Cloud machine's screen (`cloudOpenDesktop`): `web`, its noVNC
    /// page in a Chromium tab (the default); `native`, the remote view pane straight to the
    /// machine's VNC server over the app's Cloud tunnel; or `rd`, the pane showing the machine's
    /// `cmux-rd` host (H.264) over its daemon link.
    static var desktopViewerChoice: ActionArgument {
        var cases = [ActionEnumCase(value: "web", title: String(localized: "argument.value.viewerWeb", defaultValue: "Browser", bundle: .module))]
        #if DEBUG
        // The remote view pane is development-only (RemoteViewAvailability).
        cases.append(ActionEnumCase(value: "native", title: String(localized: "argument.value.viewerNative", defaultValue: "Native", bundle: .module)))
        cases.append(ActionEnumCase(value: "rd", title: String(localized: "argument.value.viewerRd", defaultValue: "Video Stream", bundle: .module)))
        #endif
        return ActionArgument(name: "viewer", title: String(localized: "argument.viewer", defaultValue: "Viewer", bundle: .module),
                              kind: .enumeration(cases), isRequired: false)
    }

    /// A device title from the daemon's list, or none (`browserDevice`).
    static var deviceString: ActionArgument {
        ActionArgument(name: "device", title: String(localized: "argument.device", defaultValue: "Device", bundle: .module), kind: .string,
                       isRequired: false)
    }

    /// portrait, landscape, unfolded-portrait or unfolded-landscape (`browserDevice`).
    static var orientationString: ActionArgument {
        ActionArgument(name: "orientation", title: String(localized: "argument.orientation", defaultValue: "Orientation", bundle: .module),
                       kind: .string, isRequired: false)
    }
}
