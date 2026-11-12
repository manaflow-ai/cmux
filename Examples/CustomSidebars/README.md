# Custom Sidebar Examples

These are vibe-coded cmux sidebars that run as interpreted SwiftUI-style files.
They do not need Xcode, signing, or a build step.

The examples intentionally keep their labels inline because interpreted
sidebars do not have a localization catalog yet.

Start with one of the six curated built-in templates from the app or CLI:

```bash
cmux sidebar templates
cmux sidebar try agents-board
cmux sidebar new agents-board --from agents-board
cmux sidebar open agents-board
```

In the app, right-click the sidebar toggle button and choose **Browse Sidebar Templates…**
to see the gallery. Try a template before keeping it, or use it and edit the file later.

The curated previews are also shown in the [custom-sidebar guide](../../docs/custom-sidebars.md#curated-gallery).

| Template | Light | Dark |
| --- | --- | --- |
| Workspaces | ![Workspaces](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/workspaces-light.png) | ![Workspaces dark](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/workspaces-dark.png) |
| Agents Board | ![Agents Board](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/agents-board-light.png) | ![Agents Board dark](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/agents-board-dark.png) |
| Panel Sessions | ![Panel Sessions](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/panel-sessions-light.png) | ![Panel Sessions dark](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/panel-sessions-dark.png) |
| Panel Subagents | ![Panel Subagents](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/panel-subagents-light.png) | ![Panel Subagents dark](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/panel-subagents-dark.png) |
| btop Agents | ![btop Agents](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/btop-agents-light.png) | ![btop Agents dark](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/btop-agents-dark.png) |
| Panel Todo | ![Panel Todo](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/panel-todo-light.png) | ![Panel Todo dark](../../Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews/panel-todo-dark.png) |

You can also copy any source file from this directory into
`~/.config/cmux/sidebars/`. Enable **Settings -> Beta features -> Custom sidebars**
then pick it from the sidebar toggle button's right-click menu. The manifest lists
the bundled templates' display name, description, and intended placement. The other
examples remain available here as authoring references.

## Included Sidebars

- `status-board.swift`: groups workspaces into urgent, review, progress,
  research, and done lanes using live PR, branch, progress, unread, and prompt
  signals.
- `finder.swift`: a macOS Finder-style workspace browser with a source list,
  selected workspace inspector, and tab list.
- `btop-agents.js`: agent activity in the spirit of btop. Each workspace shows
  a braille sparkline of how busy its agents were over the last six minutes,
  a state glyph (spinner while working, amber diamond when waiting for input),
  a tiny progress meter, unread count and PR number. The header graphs busy
  workspaces over twelve minutes. Click a row to select it, drag to reorder,
  and use BUSY to hide quiet workspaces. Install with
  `cp Examples/CustomSidebars/btop-agents.js ~/.config/cmux/sidebars/` and
  `cmux sidebar select btop-agents`.

See `docs/custom-sidebars.md` for the full authoring contract.
