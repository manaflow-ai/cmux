# CmuxSidebarScript

A small Lisp for customizing the cmux sidebar. A script's `render-row` function
receives one workspace's data and returns a view tree, which the host renders as
SwiftUI. Anything the bridge exposes (stacks, text, images, shapes, colors,
fonts, and the usual view modifiers) is available; adding a new view or modifier
is one registry entry plus one render case.

## Pipeline

```
source ──Reader──▶ [LispValue] ──Evaluator + Bridge──▶ RenderNode ──RenderNodeView──▶ SwiftUI
```

`RenderNode` is a pure, `Equatable` value tree with no SwiftUI in it. That split
is the performance contract: a sidebar row recomputes its node only when its
input data changes, and the row stays `.equatable()` over the node so SwiftUI
skips untouched rows at 1000-workspace scale. Evaluation is therefore fully unit
testable without booting SwiftUI.

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
- Views: `vstack` `hstack` `zstack` `group` `text` `image` `label` `spacer`
  `divider` `rectangle` `capsule` `circle` `rounded-rectangle` `progress-view`
  `button`.
- Options (modifiers): `:font :foreground :background :tint :padding :frame`
  (`:width :height :max-width :frame-align ...`) `:corner-radius :opacity
  :line-limit :truncation :text-align :shadow :overlay :offset :bold :italic
  :underline :strikethrough :border :help :on-tap` and more.
- Style constructors: `(color :name)` `(hex "#rrggbb")` `(rgb r g b)`
  `(font :size :weight :design)` `(gradient c1 c2 :direction)` `(edges ...)`
  `(shadow ...)`.
- Actions: `(open-url url)`, `(copy-text text)`.

A malformed script raises a localized `LispError` at compile time; a render
fault raises one per row. The host treats both as "fall back to the native row".

## Usage

```swift
let script = try SidebarScript(source: lispSource)   // parse + bind once
let node = try script.render(context)                // per row, returns RenderNode
RenderNodeView(node: node, onAction: handleAction)    // render as SwiftUI
```

`SidebarScript.makeDefault()` compiles the bundled `DefaultSidebar.lisp`.

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
