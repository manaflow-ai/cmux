# GlassHost (draft)

> Draft. Not published. Whether and how this leaves the cmux repo is a later decision.

Native macOS glass for the popovers, menus and floating controls of a web UI.

A web view can't blur what is behind its window. CSS `backdrop-filter` in a see-through
WKWebView or Chromium view only reaches the page's own pixels, so a web popover over a translucent
window either shows the window glass sharp through its tint or paints a solid card. Native menus
and popovers use the system material. GlassHost gives a web surface that same material and keeps
everything else in the page.

- **The page owns the surface.** Its content, layout, focus, keys, scrolling and dismissal stay in
  your HTML. Nothing is drawn twice and nothing is re-rendered natively.
- **The app owns only the material.** It puts one glass view per open surface at the surface's box,
  *under* a see-through web view. The page draws on top of it.
- **No flash, no pop.** A surface stays hidden until the app has drawn its glass, which takes one
  round trip. If the app hasn't answered within the deadline (50 ms by default), or doesn't support
  the call, the surface shows with the page's own look and keeps it for as long as it is open.
- **It follows the Mac.** On macOS 26 the glass is Liquid Glass (`NSGlassEffectView`). Before that it is
  the vibrancy blur in the level's system material (`.popover`, `.menu`, `.toolTip`), and under
  Reduce Transparency it is an opaque fill. It changes live when the setting changes.

It has two halves and no dependencies:

| Half | Where | Imports |
| --- | --- | --- |
| Swift | `Packages/Shared/GlassHost` (this folder) | AppKit, Foundation |
| Web | `webviews/src/glass-host` | nothing (`react.ts`: React, optional) |

`webviews/src/glass-host/boundary.test.ts` fails if either half imports anything else.

## Web API

```ts
import { createGlassHost, glassHostCss } from "./glass-host";

// Your bridge to the app: any function that delivers the list and resolves once the app drew it.
const host = createGlassHost({
  transport: (surfaces) => window.webkit.messageHandlers.glass.postMessage({ surfaces }),
  applies: () => document.documentElement.dataset.seeThrough === "1", // optional
});

// Imperative: you keep the box current.
const surface = host.open({ level: "menu", rect: { left: 10, top: 40, right: 230, bottom: 208 }, radius: 10 });
surface.position({ left: 30, top: 40, right: 250, bottom: 208 });
surface.resize(240, 200);
surface.setOpacity(0.5);
await surface.ready; // true: drawn on the app's glass; false: fell back to the page's look
surface.close();

// Bound to an element: the host follows its box, radius and opacity.
document.head.append(Object.assign(document.createElement("style"), { textContent: glassHostCss }));
host.attach(popoverElement, { level: "popover" });

// Or mark elements and let the host find them as they mount:
//   <div data-glass-level="popover">…</div>
const stop = host.observe();
```

- **Levels:** `popover` (cards, pickers, panels), `menu`, or `chip` (tooltips and small floating
  buttons).
- **Phase:** `glassHostCss` reads the `data-glass-host` attribute on an attached element
  (`pending`, `drawn` or `fallback`). It hides the element while pending, and once drawn it removes
  the element's own fill and blur. Set `--glass-host-fill` to keep a veil of your own on the glass.
- **React:** `useGlassSurface(host, ref, { level, open })` from `react.ts`. It returns the phase.

### The wire

Each report is the whole list of open surfaces:

```json
[{ "id": "g1", "level": "menu", "left": 30, "top": 40, "right": 250, "bottom": 208, "radius": 10, "opacity": 1 }]
```

- Coordinates are CSS pixels from the viewport's top-left.
- A new surface reports in the same task it opened in. Later changes coalesce to one report per
  animation frame.
- A report is sent only when the list changed. An attached element is re-read each frame while it
  moves, and that stops after three still frames.
- Because the native side gets the full state every time, a lost report is corrected by the next
  one.

## Swift API

```swift
import GlassHost

let glass = GlassHostView()
glass.place(under: webView)            // same superview, right under the web view, at its frame

// Your bridge's handler: decode, draw, then answer, so the page shows the surface on drawn glass.
func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
          let surfaces = GlassSurfaceState.decode(body["surfaces"]) else { return /* reply: refused */ }
    glass.apply(surfaces, zoom: webView.pageZoom)
    // reply: ok
}

// After a layout that moves the web view:
glass.place(under: webView)
```

- `GlassSurfaceState.decode` refuses the whole message if any part is bad: a missing or non-finite
  number, an inverted box, an unknown level, a repeated id, an opacity outside 0...1, or more than
  16 surfaces.
- `GlassHostView` takes no clicks. The page above it takes every click on its surfaces.
- **Your own material:** set `glass.makeSurface = { level in MyGlassView(level) }`, where your view
  conforms to `GlassSurfaceView` (an `NSView` with a `cornerRadius`). cmux uses this to keep its
  themed tint and rim.
- **Defaults:** `GlassMaterialView(level:)` is the default material. Its `tintColor` lays a tint on
  the glass.

### Requirements

- macOS 14 or later.
- The web view must be see-through where its surfaces are:
  - WKWebView: `underPageBackgroundColor = .clear` with drawsBackground off.
  - Chromium: a transparent background.

  Otherwise the page's background covers the glass. Report nothing while it is opaque
  (`applies: () => false`).

## What it is not

- It is not a native menu renderer. Plain command menus can be real `NSMenu`s. GlassHost is for
  surfaces whose content belongs in the page.
- It doesn't blur the page's own pixels under a surface. In a see-through Chromium page, text
  under a popover is still the page's own drawing. Leave it out of the surface's box, or blur it in
  place (cmux does both).
- It is not a separate window. The glass sits in the web view's own window, so it moves, clips and
  orders with the page for free.

## Status in cmux

- cmux#37585 is the first in-app use (Session Info), and cmuxterm-hq#7522 lists the surfaces still
  to convert.
- cmux will adopt this package in place of its in-app copy (`AgentPaneView+HostGlass`,
  `ui/glass/hostGlass.ts`) once that PR lands.
- Gallery: `glass-host.package`.
