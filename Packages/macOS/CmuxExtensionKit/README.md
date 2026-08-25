# CMUX Extension Kit

`CmuxExtensionKit` is the zero-dependency public SDK for CMUX sidebar extensions
and language-neutral, process-backed plugins.

## Process-backed plugins (API 3.0)

The first plugin slice is intentionally small and complete: a plugin can
subscribe to lifecycle events and register command-palette actions. Plugins
run as ordinary child processes, so they can be written in Swift, Python,
JavaScript, Rust, or any other language that can speak JSON over a Unix socket.

### Directory layout

Install each plugin below:

```text
~/Library/Application Support/cmux/plugins/<id>/
├── manifest.json
└── bin/plugin                 # executable declared by `entrypoint`
```

The directory name must exactly match `id`. CMUX ignores a missing directory,
but keeps malformed manifests and missing executables as load errors in
Settings. Entry points must be relative and must remain inside the plugin
directory after symlink resolution.

### Manifest

```json
{
  "id": "dev.example.plugin",
  "displayName": "Example Plugin",
  "kind": "plugin",
  "minimumAPIVersion": { "major": 3, "minor": 0 },
  "pluginScopes": ["eventHooks", "paletteActions"],
  "eventSubscriptions": ["workspace.created", "notification.created"],
  "actions": [
    { "id": "open-dashboard", "title": "Open Dashboard", "keywords": ["dashboard"] }
  ],
  "entrypoint": "bin/plugin"
}
```

`eventHooks` and `paletteActions` are explicit capability families. Declaring
an event or action without its family is rejected. Every plugin is disabled
until the user reviews its requested scopes in Settings → Automation. A
manifest or bundle-content fingerprint change invalidates the previous
approval. Approved processes launch from a revalidated private bundle snapshot,
and the entrypoint is executed through a pinned descriptor. The complete launch
snapshot is read-only, so source-directory, sibling-file, or snapshot-path
replacement cannot change the bytes that receive the reviewed capabilities.
Shebang entrypoints also launch through an opened interpreter descriptor; use an
absolute executable interpreter path when writing scripts.
Use `TMPDIR` or another application-data location for plugin-generated files.
Disabling a plugin preserves the reviewed grant but stops its process and event
stream.
The process-backed core slice keeps the original sidebar `readScopes` and
`actionScopes` separate; declaring those sidebar-only scopes in a process
plugin is rejected until a future host combines the two transports.

Plugins are ordinary executables running as the signed-in macOS user, not
sandboxed app extensions. The reviewed scopes limit data and actions exposed
by cmux's plugin transport; they do not restrict the executable's normal
filesystem or network access. Install plugins only from sources you trust.

### Process environment

When enabled, CMUX launches the validated entry point with these variables:

| Variable | Meaning |
| --- | --- |
| `CMUX_PLUGIN_ID` | Manifest `id`. |
| `CMUX_PLUGIN_TOKEN` | In-memory capability token for this process. |
| `CMUX_PLUGIN_SOCKET_PATH` | Active CMUX control-socket path. |
| `CMUX_PLUGIN_MANIFEST_PATH` | Absolute path to `manifest.json`. |
| `CMUX_PLUGIN_API_VERSION` | Plugin API selected by the host as `major.minor`. |
| `CMUX_SOCKET_PATH` | Alias for the active socket path. |

### Event subscription

Use the existing `events.stream` request. The host intersects requested names
with the approved manifest declarations and rejects an invalid token or
unapproved event before opening the stream:

```json
{
  "id": "subscribe-1",
  "method": "events.stream",
  "params": {
    "plugin_id": "dev.example.plugin",
    "plugin_token": "$CMUX_PLUGIN_TOKEN",
    "names": ["workspace.created", "notification.created", "plugin.action.invoked"],
    "include_heartbeats": true
  }
}
```

Events use the existing `cmux-events` JSON-lines envelope (`protocol`,
`version`, `boot_id`, `seq`, `name`, `category`, IDs, and `payload`). The stable
lifecycle names are:

`workspace.created`, `workspace.closed`, `pane.created`, `pane.closed`,
`surface.created`, `surface.closed`, `agent.session.started`,
`agent.session.state_changed`, `agent.session.ended`, `notification.created`,
and `git.branch.changed`.

`plugin.action.invoked` is an implicit private subscription granted by the
`paletteActions` scope; it is not listed in `eventSubscriptions`. Include it in
the stream request whenever the plugin declares actions, or omit `names` to
subscribe to every event approved for that plugin. CMUX exposes the plugin's
palette and keyboard actions only while that action receiver is connected, so
an invocation is never knowingly routed into a disconnected process.

### Action invocation

Each action appears in the command palette as `plugin.<id>.<action>`. When the
user invokes it (from the palette or its optional keyboard binding), CMUX sends
the owning plugin a `plugin.action.invoked` event with this payload:

```json
{
  "plugin_id": "dev.example.plugin",
  "action_id": "open-dashboard",
  "invocation_id": "…",
  "occurred_at": "2026-01-01T00:00:00Z",
  "context": {}
}
```

Action shortcuts are editable in Settings → Keyboard Shortcuts and stored in
the shared `~/.config/cmux/cmux.json` file under
`shortcuts.pluginBindings`:

```json
{
  "shortcuts": {
    "pluginBindings": {
      "plugin.dev.example.plugin.open-dashboard": "cmd+shift+d"
    }
  }
}
```

The map uses the same modifier/key syntax as built-in shortcut bindings. A
binding is namespaced by the complete `plugin.<id>.<action>` id, is checked for
conflicts with built-in and other enabled plugin actions, and is ignored when
the plugin is disabled or its approval is revoked.

### Current limits and follow-ups

`paneContent` and `workspaceBadges` are part of the manifest vocabulary for
forward compatibility, but this core slice rejects them until the host wires
browser/markdown pane hosting and workspace badge projection. Follow-up work
should add those surfaces, per-plugin event backpressure/health controls, and
an explicit permission-review sheet that lets users approve individual
declarations instead of the current approve-all action.

The original sidebar API remains available alongside the process-backed plugin
transport. Sidebar extensions expose a stable workspace snapshot and typed
action channels:

- read the current sidebar snapshot
- create, select, navigate, and close workspaces
- create, select, navigate, split, zoom, and close surfaces
- ask CMUX to open a URL

The snapshot includes workspace identity, title, detail text, paths, git branch, unread state, listening ports, pull request URLs, and shared surface metadata. It does not expose terminal buffers, shell history, environment variables, secrets, or arbitrary filesystem access.

Host-side lifecycle, discovery, and display belong in
`Packages/macOS/CmuxSidebar/Sources/CmuxSidebar/ExtensionHost`.
Internal cmux-owned sidebar provider/render models live in `Packages/macOS/CmuxSidebarProviderKit`.
They are separate from the public extension-author SDK.

## Five-Minute Sidebar Extension

Sidebar extensions are ExtensionKit app extensions. `CmuxExtensionKit` and the reference projects target macOS 14+, matching CMUX.

Use [`Examples/SampleSidebarExtensionApp`](../../../Examples/SampleSidebarExtensionApp)
as the reference project:

1. Open `SampleSidebarExtensionApp.xcodeproj`.
2. Change the app and extension bundle identifiers to your own reverse-DNS prefix.
3. Change the signing team from Manaflow to your team.
4. Keep the extension point identifier as `com.cmuxterm.app.cmux.sidebar`.
5. Keep App Sandbox enabled for the extension target.
6. Build and launch the containing app once so macOS registers the embedded extension.
7. In CMUX, open Sidebar Extensions from the puzzle button next to the sidebar
   help button and enable your extension.
8. Choose the extension sidebar provider from that puzzle menu.
9. If more than one sidebar extension is enabled, choose your extension from the
   extension sidebar header.

The extension target declares the extension point in its `Info.plist`. The
reference project gives this build setting the production value
`com.cmuxterm.app.cmux.sidebar`; the tagged development helper overrides it to
match the tagged host:

```xml
<key>EXAppExtensionAttributes</key>
<dict>
  <key>EXExtensionPointIdentifier</key>
  <string>$(CMUX_SIDEBAR_EXTENSION_POINT_ID)</string>
</dict>
```

Define your ExtensionKit entrypoint by conforming directly to `CmuxSidebarExtension`.
The SDK refines `ExtensionFoundation.AppExtension`, supplies the ExtensionKit
configuration, owns the scene/XPC wiring, and uses the stable sidebar scene ID.
Your extension provides the manifest, SwiftUI view, and update handling:

```swift
import CmuxExtensionKit
import Observation
import SwiftUI

@main
@Observable
@MainActor
final class ExampleSidebarExtension: CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "dev.example.sidebar",
        displayName: String(localized: "exampleSidebar.manifest.displayName", defaultValue: "Example Sidebar"),
        readScopes: [.workspaceMetadata],
        actionScopes: [.selectWorkspace]
    )

    private(set) var snapshot: CmuxSidebarSnapshot?
    private var host: CmuxSidebarHost?

    required init() {}

    var body: some View {
        List(snapshot?.workspaces ?? []) { workspace in
            Button(workspace.title) {
                Task { @MainActor in
                    try? await host?.selectWorkspace(workspace.id)
                }
            }
        }
    }

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        // Update optional connection UI here.
    }
}
```

## Extension Protocols

`CmuxSidebarExtension` is the public extension protocol. It refines `AppExtension`,
requires a manifest and SwiftUI `body`, and delivers `CmuxSidebarContext`, which
contains the filtered `CmuxSidebarSnapshot` and a typed `CmuxSidebarHost` command
channel.

The lower-level transport lives behind CMUX host SPI. New sidebar extensions should
conform to `CmuxSidebarExtension` and should not handle XPC directly.

`connectionStatusDidChange(_:)` reports `.connected`, `.waitingForHost`, or
`.error(String)` when the host connection changes. Extensions that do not show
connection state can omit the method.

`context.host` is the public command channel for sidebar extensions. It exposes
typed helpers for workspace, surface, and URL actions. Raw transport setup and
host-side callbacks are SPI for CMUX's own host implementation.
Creating or splitting a browser surface with a URL requires both the surface
action scope and `openURL`.

## Running External Tools

`CmuxExtensionKit` permissions govern the data and actions CMUX shares with an
extension. They do not relax the macOS App Sandbox or grant filesystem access.
A child process inherits the extension's sandbox, so apply all of the following
when launching `git` or another command-line tool.

### Keep the extension sandboxed

Leave **App Sandbox** enabled on the appex target
(`ENABLE_APP_SANDBOX = YES`). An unsandboxed ExtensionKit appex can compile,
embed, and sign but never register, with no useful error in CMUX. Check
registration independently of CMUX with:

```sh
pluginkit -mAvvv
```

The normal CMUX release uses `com.cmuxterm.app.cmux.sidebar`. Tagged development
builds use the point stored in the host's `CMUXSidebarExtensionPointIdentifier`
Info.plist key (currently `<host-bundle-id>.cmux.sidebar`). If the extension is
absent from the unfiltered output, fix its sandbox, signing, bundle identifier,
and extension point before debugging the CMUX connection.

### Launch the real executable, not an Xcode shim

Do not launch `/usr/bin/git` from an extension. On macOS it is an Xcode
tool-selection shim that resolves the active developer tool through `xcrun`,
and `xcrun` cannot run inside App Sandbox. Other developer-tool shims under
`/usr/bin` have the same limitation.

```text
xcrun: error: cannot be used within an App Sandbox.
```

For local development, real Git paths reported to avoid the Xcode shim include:

- `/opt/homebrew/bin/git`
- `/Library/Developer/CommandLineTools/usr/bin/git`
- `/Applications/Xcode.app/Contents/Developer/usr/bin/git`

Treat host-installed paths as development-only diagnostics, not portable
distribution targets: their availability and sandbox access vary by machine.
Even if one launches in a local development setup, App Sandbox user-selected
file access authorizes data access, not execution of arbitrary host binaries.
For a distributed extension, follow Apple's [sandboxed command-line helper
guidance](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app):
embed and sign the required executable or helper in the extension's own bundle.
The helper should carry the App Sandbox and sandbox-inheritance entitlements
(`com.apple.security.app-sandbox` and `com.apple.security.inherit`). A child tool
still inherits the extension's sandbox and file access.

### Set a readable working directory

Always set `Process.currentDirectoryURL` before launch. ExtensionKit may start
the appex in a directory that its sandbox cannot read. Tools that inspect their
inherited working directory can then fail before doing useful work:

```text
fatal: Unable to read current working directory: Operation not permitted
```

Use an already authorized directory, normally the repository:

```swift
let process = Process()
process.executableURL = gitURL
process.currentDirectoryURL = repositoryURL
process.arguments = ["status", "--short"]
```

If you keep `-C`, still set `currentDirectoryURL` to a readable directory.
Current Git accepts `-C` as a global option before the subcommand
(`git -C <repository> status`), but not as a `status` option; an explicit
`currentDirectoryURL` also protects launches of other tools that do not have a
Git-style override.

### Authorize repository access explicitly

A `workspacePaths` grant tells the extension where a repository is; it does not
authorize the extension process to open it. CMUX also does not broker command
execution or bookmark data: `CmuxSidebarHost` exposes typed workspace, surface,
and URL actions only. The extension owns every `Process` it starts and every
filesystem grant that process needs.

Enable the appropriate **User Selected File** entitlement on the extension
target and have the user choose the repository with a standard Open panel. If
the containing app owns selection instead, transfer URL bookmark data through
an app-owned channel, such as storage shared by an App Group; the current
`CmuxExtensionKit` XPC channel does not carry arbitrary bookmark payloads. Both
targets need the capabilities required by that channel. Resolve the bookmark in
the extension and keep the authorized URL's security-scoped access active for
the entire child-process lifetime. Apple's [macOS App Sandbox file-access
guide](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
distinguishes live interprocess URL bookmarks from persistent security-scoped
bookmarks and documents App Group storage.

Privacy controls such as Files and Folders still apply to locations including
Desktop, Documents, and Downloads. [Apple documents embedded
extensions](https://support.apple.com/guide/security/supporting-extensions-secabd3504cd/web)
as sharing their containing app's privacy-control grants, but CMUX is the
activating host, not the app that contains a third-party sidebar. That is
separate from App Sandbox repository access: use explicit selection and
bookmarks, and handle denial without assuming that extension activation will
present a consent prompt.

Full Disk Access is a user-granted System Settings permission intended for
workflows that genuinely need access across the disk. If a broad-disk workflow
still receives a denial during development, System Settings may require
selecting the embedded `.appex` explicitly. Do not make it the normal setup path
for a sidebar that reads selected repositories; prefer explicit selection and
bookmarks.

If you test privacy grants during development, sign the appex with a stable
Apple Development or self-signed identity. An ad-hoc signature's designated
requirement is derived from the changing binary hash, so a rebuild can be
treated as a different program and lose an existing privacy decision.

## Permissions

List every scope and action your extension needs in its manifest. CMUX filters the
snapshot and rejects actions that have not been granted:

- `workspaceList`: workspace identities and ordering only
- `workspaceMetadata`: workspace names, branches, unread counts, and selection
- `surfaceMetadata`: shared tab/surface names, kinds, focus, and unread counts
- `workspacePaths`: local workspace and project paths
- `notifications`: latest workspace notifications
- `networkPorts`: listening ports for each workspace
- `pullRequests`: pull request links associated with workspaces
- `createWorkspace`: create workspaces
- `selectWorkspace`: select a workspace from your UI
- `closeWorkspace`: close workspaces from your UI
- `createSurface`: create terminal and browser surfaces
- `selectSurface`: select a surface within a workspace
- `closeSurface`: close a surface
- `splitSurface`: split a terminal or browser surface
- `zoomSurface`: toggle surface zoom
- `navigateWorkspace`: select the next or previous workspace
- `navigateSurface`: select the next or previous surface
- `openURL`: open links from your UI
- `createWorkspaceWithPath`: create workspaces for specific local folders

If your extension does not appear, confirm the containing app has been launched, the embedded appex is signed by your team, the extension point identifier is unchanged, and CMUX's Sidebar Extensions browser shows the extension as enabled.
