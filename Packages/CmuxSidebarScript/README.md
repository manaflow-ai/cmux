# CmuxSidebarScript

A small Lisp for customizing the cmux sidebar. A script can define
`render-sidebar` to own the entire sidebar surface. Legacy scripts can still
define `render-row` to customize one workspace row inside the native list.
Anything the bridge exposes (stacks, text, images, shapes, colors, fonts, and
the usual view modifiers) is available; adding a new view or modifier is one
registry entry plus one render case.

## Pipeline

```
source ──Reader──▶ [LispValue] ──Evaluator + Bridge──▶ RenderNode ──RenderNodeView──▶ SwiftUI
```

`RenderNode` is a pure, `Equatable` value tree with no SwiftUI in it. That split
is the performance contract: scripts render deterministic node trees from data,
and evaluation is fully unit testable without booting SwiftUI. Row scripts keep
the old per-row `.equatable()` behavior; whole-sidebar scripts trade native row
chrome for complete layout control.

## Language

Scheme-ish core with one ergonomic twist: view options are `:keyword` arguments,
so a form reads like SwiftUI.

```lisp
(vstack :spacing 4 :max-width infinity :frame-align leading
  (text (get ws :title)
    :font (font :size 13 :weight semibold)
    :foreground (color :primary)
    :line-limit 1
    :truncation tail)
  (when (get ws :branch)
    (hstack :spacing 4
      (image :system "arrow.triangle.branch" :font (font :size 10))
      (text (get ws :branch) :font (font :size 10 :design monospaced)))))
```

- Special forms: `if`, `when`, `unless`, `cond`, `and`, `or`, `let`, `def`,
  `fn`/`lambda`, `set!`, `do`, `quote`.
- Data: ints, doubles, strings, `true`/`false`/`nil`, `:keywords`, lists, and
  records (maps) read with `(get record :key default)`.
- Library: arithmetic, comparisons, `map`/`filter`/`reduce`, list and string
  ops, `str`/`join`, `record`/`assoc`/`get`/`keys`.
- Views: `vstack` `hstack` `zstack` `grid` `group` `text` `image` `label`
  `spacer` `divider` `rectangle` `capsule` `circle` `rounded-rectangle`
  `progress-view` `button`.
- Options (modifiers): `:font :foreground :background :tint :padding :frame`
  (`:width :height :max-width :frame-align ...`) `:corner-radius :opacity
  :line-limit :minimum-scale-factor :truncation :text-align :shadow :overlay
  :offset :scale :mask :bold :italic :underline :strikethrough :border :help
  :on-tap` and more.
- Style constructors: `(color :name)` `(hex "#rrggbb")` `(rgb r g b)`
  `(font :size :weight :design)` `(gradient c1 c2 :direction)` `(edges ...)`
  `(shadow ...)`.
- Actions: `(open-url url)`, `(copy-text text)`, `(select-workspace ws-or-id)`,
  `(close-workspace ws-or-id)`, `(new-workspace :title "Scratch" :directory "/path")`,
  `(open-workspace file-or-directory)`, `(set-sidebar-state key value)`,
  `(toggle-sidebar-state key)`.

A malformed script raises a localized `LispError` at compile time. A whole
sidebar render fault falls back to the native sidebar; a row render fault falls
back to the native row. Top-level bindings are frozen after compile, so renders
stay deterministic for a given input. `set!` is still available for local `let`
bindings inside one render pass.

## Usage

```swift
let script = try SidebarScript(source: lispSource)   // parse + bind once
let node = try script.renderSidebar(sidebarContext)   // whole sidebar RenderNode
RenderNodeView(node: node, onAction: handleAction)    // render as SwiftUI
```

Whole-sidebar scripts receive a record with `:workspaces`, `:workspace-count`,
`:selected-workspace-id`, `:window-id`, and `:dark-mode`. Each workspace record
also has `:id`, `:index`, `:title`, `:detail`, `:branch`, `:directory`,
`:directories`, `:pull-requests`, `:ports`, `:unread`, `:pinned`, `:active`,
`:selected`, `:color`, `:message`, `:progress`, `:remote`, `:status`, and
`:files`. File records expose `:name`, `:path`, `:directory`,
`:workspace-title`, and `:workspace-directory`, so a Finder-like sidebar can
turn each file or folder into a workspace launch target. Whole-sidebar scripts
also receive `:state`, a persisted string map stored at
`~/.config/cmux/sidebar-state.json`.

`SidebarScript.makeDefault()` compiles the bundled `DefaultSidebar.lisp`.

Bundled demos live in `Sources/CmuxSidebarScript/Resources/` and are exposed by
`SidebarScriptDemo.all`:

- `DefaultSidebar.lisp`: the normal rich workspace row.
- `LiquidGlassSidebar.lisp`: a full-sidebar layered poster layout.
- `HighDensityIDESidebar.lisp`: a full-sidebar dense IDE matrix.
- `TerminalStealthSidebar.lisp`: a full-sidebar terminal transcript.
- `ProStudioSidebar.lisp`: a full-sidebar production timeline.
- `FinderSidebar.lisp`: a full-sidebar Finder-like hierarchy.
- `AgentOpsSidebar.lisp`: a full-sidebar ops dashboard.

The bridge intentionally does not execute arbitrary Swift. To support more of
SwiftUI, add view constructors or modifiers to `Bridge` and `RenderNodeView`.
That preserves deterministic rendering, row equatability, and native fallback
when a user script fails.

## Testing

Everything but `RenderNodeView` is pure and host-free. Evaluate a string and
inspect the resulting node tree:

```swift
let node = try SidebarScript(source: """
    (def (render-row ws) (text (upper (get ws :title))))
    """).render(SidebarScriptContext(title: "hello"))
#expect(node.containsText("HELLO"))
```

No global state: `SidebarScript` takes its source via `init`, and tests build
`SidebarScriptContext` values directly. Run with `swift test`.
