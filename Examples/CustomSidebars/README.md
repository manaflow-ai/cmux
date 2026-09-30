# Custom Sidebar Examples

These are vibe-coded cmux sidebars that run as interpreted SwiftUI-style files.
They do not need Xcode, signing, or a build step.

The examples intentionally keep their labels inline because interpreted
sidebars do not have a localization catalog yet.

Install one by copying it into your custom sidebar directory:

```bash
mkdir -p ~/.config/cmux/sidebars
cp Examples/CustomSidebars/status-board.swift ~/.config/cmux/sidebars/status-board.swift
cp Examples/CustomSidebars/finder.swift ~/.config/cmux/sidebars/finder.swift
```

Then enable **Settings -> Beta features -> Custom sidebars** and pick it from
the sidebar toggle button's right-click menu.

You can validate a copied sidebar with:

```bash
cmux sidebar validate status-board
cmux sidebar validate finder
```

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
