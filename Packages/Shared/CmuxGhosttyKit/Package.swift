// swift-tools-version: 6.0

import PackageDescription

// The one libghostty binary for cmux-next: GhosttyNextKit from
// manaflow-ai/ghostty-next (plans/cmux-next/ghostty-next-switch.md). The Mac
// app (CmuxNextTerminal) and the iOS app (CmuxiOSTerminal) both depend on
// this product, so the workspace resolves exactly one binary target of that
// name. Flavor apple-v6: macOS arm64 + x86_64, iOS, iOS simulator. Since
// 59a70ffc6 the iOS keycode in ghostty_input_key_s is the USB HID usage
// (UIKey.keyCode); macOS keeps Mac virtual keycodes. Since 68ac618db a
// GHOSTSNP READY restore applies this surface's palette, default colors and
// cursor defaults as local policy (ghostty-next PR 20).
// Since bbb7320b4 it restores a READY cut at the owner's resize with the
// surface's own reflowed history, checked by the history digest (PR 23).
// Since 94fe86949 it applies the owner's Kitty image replay on a trusted path
// (ghostty_surface_apply_kitty_replay; PR 24), keeps images across a
// local-history restore with no frame between its swaps (PR 26), and fetches
// its build dependencies from our release mirror (PR 25).
// Since 3320bd06e the Apple slices contain no GNU libintl (i18n off; PR 27).
// Since 3339f2ada it reports OSC 7501 program status (ghostty-next PR 29).
// Since 673a6369c its terminfo and XTGETTCAP advertise Pst (PR 32), and its
// non-Darwin builds localize compiler-rt's libSystem symbols (PR 31).
// Since c41410256 the app can veto a hover regex link
// (ghostty_surface_set_link_filter; PR 33).
// Since 89dc50175 ghostty_config_get reads a plain TerminalColor
// (cursor-color, cursor-text, selection-*) as a color (PR 34).
// Since 03ddb2869 the Metal text shader contrasts against the real
// background under a macOS glass style, so minimum-contrast keeps dark text
// dark on a light theme (PR 35).
// Since 4792f0307 it does the same at background-opacity 0, which cmux-next
// gives its surfaces in a translucent window (PR 36).
// Since 48d353b8c a macOS surface can be host-sized
// (ghostty_surface_set_host_sized): its target follows set_size, not the
// view's bounds, so a pane drag keeps the last frame (PR 38).
// Since c5926d664 a host-locked mirror draws its own reflow at the view's
// grid until the owner announces it (ghostty_surface_set_reflow_preview),
// and reports the grid its last frame drew (ghostty_surface_drawn_grid;
// PR 39).
// Since e4831af81 cells keep the source of each color and a config color
// change blends on the GPU with the surface's transition
// (ghostty_surface_set_color_transition), and the renderer reports its
// frame counters (ghostty_surface_render_counters; PR 40).
// Since e6a27a1fb a config change of colors only rebuilds no cells, and the
// render counters report full rebuilds by cause (PR 41).
// Since a19c884fa a released drawable keeps its pixels while another owner
// holds it (the layer's presented frame, an evicted terminal's last frame;
// cmux marks those volatile while hidden; PR 42).
// Since ced99dcde a new drawn terminal (a restore, the reflow preview) keeps
// rows whose content is the same (PR 43) and the renderer's cell size
// follows its font grid only (PR 44), so a font change rebuilds once.
// Since e923d79f1 CSI ? 996 n and mode 2031 report the surface's runtime
// color scheme, so a plain theme in dark mode answers dark (PR 37).
// Since a04c57e81 a snapshot restore keeps a scrolled-back viewport on the
// rows it showed, and a scroll no longer turns the next local-history
// restore into a full resend.
// Since 43ffe4171 narrowing a padded multi-line prompt (Powerlevel10k
// "lean, 2 lines") lets zsh redraw it without a copy of line 1 (#21341).
// Since 5555f4220 the zsh and fish integration marks ask for prompt redraw
// (redraw=1), so daemon terminals (libghostty-vt, redraw off by default)
// clear the prompt on resize too; the app already did. 493a8871b adds the
// unused C API option GHOSTTY_TERMINAL_OPT_SHELL_REDRAWS_PROMPT.
// Since 72578da21 the bash integration forks nothing per command on bash 5.3
// and nothing at start when .bashrc sets PROMPT_COMMAND (PR 47).
// Since 7d5fa1573 a mirror's pixel-only resize leaves its terminal alone
// (mode 2026 survives a drag) and never waits for the terminal lock; a
// local-history restore holds frames only when it must; a hidden surface's
// output and a hidden or steady cursor's blink wake nothing (PR 46). Its
// display-pass present of a resize frame never ran in cmux (the layer gets
// no display pass for a size change).
// Since 1f98b11be..b42d1690e (PRs 48-50): ghostty_surface_present_host_frame
// lets the embedder present a new host size's frame before the commit (cmux
// does not call it yet: in a light drag it cost main 4-9 ms p95 per frame and
// more dropped frames, ghostty-integration-DESIGN.md G1); a scroll during a
// restore holds frames; a hidden surface reads as hidden at once; an early
// draw happens only after a quiet refresh interval (busy terminals no longer
// draw twice per interval); a fresh frame publishes only while a present is
// armed and in its own size generation; a reveal arms it.
// Since f3de4f4..723c4ab (PRs 52, 53 and the kitty ports): a wheel scroll
// never waits on the main thread for the terminal lock held by output
// parsing (it goes to the termio thread, applied in the mode the terminal
// has then); ghostty_surface_fit_grid gives the grid a size will fit without
// resizing; the grid metrics say whether the alternate screen is active;
// kitty graphics follow upstream #14811 and #14812.
// Since 0cb7e1e04..9ce9b7d08: ghostty_surface_present_host_frame_ready
// presents a drawn host-size frame without waiting, a content-only frame of a
// host-sized surface reaches the screen without the main thread, the bash
// 4.4-5.2 integration reads the history entry without a second fork, and an
// iOS renderer has vsync: a CADisplayLink (80-120 Hz, 120 preferred) paces
// draws to at most one per display refresh (it drew one per output batch,
// 190-270 frames a second on a 120 Hz iPhone).
//
// Since 9ce9b7d08..34e73ba8b (release/cmux-9ce9b7d0-e2: the pin plus only
// fork PR #66 and the release workflow of #67): a scroll region scroll breaks
// the soft wrap across its edges, and the unwrapping formatter carries blank
// cells only across a joined wrap (VT fuzz finding E2: the attach replay drew
// the row under a DECSTBM region 43 or 163 columns to the right). The edge
// break reads a compressed history row only when the pair was joined, and
// a clear of rows (ED, DECALN) breaks the wrap across the cleared rows' edges.
//
// Since 34e73ba8b..635c6c12a (release/cmux-9ce9b7d0-e2, fork PRs #69 and #70):
// each link regex is compiled once per process (#69), and, opt-in on macOS
// (ghostty_surface_set_host_present EMBEDDER), the embedder shows a new host
// size's frame itself with ghostty_surface_host_frame in the transaction that
// gives the view its bounds, and reports its commit with
// ghostty_surface_host_frame_committed (#70; cmux FRAME OWNER REFACTOR S4,
// the frame owner).
//
// Since 635c6c12a..7d43bb68b (release/cmux-9ce9b7d0-e2, fork PR #71): an
// off-main present never commits while it holds [CATransaction lock]. #70's
// embedder mode committed under the lock and deadlocked against main's
// commit (cmux S4 films with the switch on, STATUS 9732).
//
// Since 7d43bb68b..6cc749a8a (release/cmux-9ce9b7d0-e2, fork PRs #72, #73 and #75):
// the host-frame present's lock-span rule in ghostty.h (#72), each surface's
// thread wakes counted by source in ghostty_surface_render_counters (#73), and,
// with the embedder presenting host sizes, a frame kept for its present that
// the layer cannot show in its bounds wakes no main-queue block (#75; cmux
// FRAME OWNER S4's held-key cost: one main wake per moving terminal and frame).
//
// Since 6cc749a8a..12ec155e1 (fork PRs #77 and #79): an off-main present begins
// a Core Animation transaction only for a frame it shows (#79; cmux FRAME
// OWNER S4 profile 4b41c42c: each frame that went through main committed an
// empty transaction on the GPU completion thread), and one shared drop rule
// with its test (#77).
//
// Since 12ec155e1..383b27d73 (ghostty-next main after PR #74, which merged
// both the release line up to 12ec155e1 and its sync-line ports #76, #78,
// #80; same source tree as 706c6963a): the fork takes upstream Ghostty main c7f68a7f4 (2026-11-03,
// after v1.4.0) and needs Zig 0.17.0. Upstream's main-thread CVDisplayLink
// start and stop (ffaaf5d7a) ends the freeze where ghostty_surface_free joined
// a renderer stuck in CVDisplayLinkStop (cmux #35300). Upstream also declares
// pointer nullability in ghostty.h (0e067ded7, assume_nonnull); the fork's
// declarations are annotated to match, and the Swift callers follow it.
//
// Since 383b27d73..850bb9849 (fork PR #84, the port of #83 to main): a reflow
// preview frame whose only change is the grid (each frame of a key resize or a
// divider drag) re-wraps a kept copy of the terminal with no terminal lock
// held; the live terminal is copied under the lock only when it changed. No C
// API change (cmux-ad m18, T-REWRAP).
//
// Since 850bb9849..1740c4452 (fork PR #85): a resize's OSC 133 prompt clear
// waits for the shell's next byte and runs only if the grid differs from the
// grid the shell drew at (option PROMPT_REDRAW_WAITS_FOR_SHELL, 1028; the
// app's surfaces turn it on in termio Manual). A size bounce the shell reads
// as one SIGWINCH no longer leaves a new pane empty (close-then-type P0).
//
// Since 1740c4452..538a3e2ef (fork PR #86): while cmux presents host sizes
// and a frame of a new host size waits for that present, every renderer
// update draws at once (Thread drawsNow, Metal.hostFrameWaits), not at the
// next display-link tick: the program's redraw for the grid just sent is in
// the frame cmux presents (RESIZE P0 10, T render hop). A frame the renderer
// shows itself at the host size ends the wait, so at rest output stays paced.
//
// Since 538a3e2ef..2db2ea423 (fork PR #87, stacked on #86): host frames say
// whether the program drew at their grid. ghostty_surface_host_frame(false)
// returns READY_PROGRAM (7) for a frame drawn after program output parsed since
// the last grid change, READY for a frame of the size only, and a
// program-fresh frame turns the main run loop when it completes, so cmux's
// presenter can hold a resize's frame for the program's redraw (RESIZE P0 12).
//
// Since 2db2ea423..8e881185b (fork PR #88, stacked on #87): READY_PROGRAM
// means the program redrew the whole new grid, not only that it wrote output.
// A picture begins at a synchronized update, a cursor home, a full clear or a
// line feed; it counts when it reaches the last row and column without going
// past the grid (RESIZE P0 13). An old-grid frame (a program that repaints
// for the size it read before the change) no longer ends cmux's hold.
//
// Since 8e881185b..7a372c740 (release/cmux-538a3e2e-resize-p0-16): a full
// clear that begins a picture no longer reaches the last row by itself; the
// picture reaches it once the program printed on the grid's last two rows.
// ncurses (htop) writes its repaint after the clear in several reads, so the
// first read's end showed a nearly empty frame (RESIZE P0 16).
//
// Since 538a3e2ef..8379ecc8a (fork PR #90, release branch
// release/cmux-538a3e2e-upstream-picks): upstream #15111 (one-scan style runs
// in RowBuilder.scan) and #15121 (RefCountedSet reuses dead IDs instead of
// a whole-page clone), picked onto the #86 pin. ghostty-bench: 1.24-1.62x on
// styled and hyperlink streams and render-state updates.
//
// b3a5ebfdf (release/cmux-538a3e2e-resize-p0-22) merges 8379ecc8a into
// 7a372c740: both changes above in one pin (RESIZE P0 22).
//
// Since b3a5ebfdf..a0975fd8c (release/cmux-gi-pin-sync-2, GI PIN SYNC): five
// upstream Ghostty main commits picked onto b3a5ebfdf with `cherry-pick -x`:
// 96d379822 and 15a443234 (RenderState.endUpdate looks up a row's styles
// once per segment and walks the pending style runs as a shrinking slice:
// less work per scrolled row), 321a32a42 (a resize that grows rows and
// shrinks columns keeps the scrollback it pulled down), 5ce2325ec (a shrink
// with no scrollback no longer leaves the cursor pin garbage, so a Kitty
// image at the cursor draws) and 1b8b3f55b (pins are remapped when the
// column backfill stops early: no viewport on a freed page). No C API change.
//
// Since a0975fd8c..c370b103a (release/cmux-gi-land-1 merges a0975fd8c and
// a0e665d4f, release/cmux-gi-present-cb-1; ghostty-integration step 3):
// ghostty_surface_set_present_callback reports each frame that becomes the
// layer's contents (pixel size, content or resize, sequence, host time); it
// replaces cmux's setContents: swizzle on IOSurfaceLayer.
//
// Since c370b103a..b37a94dfe (release/cmux-gi-land-1-cell-guard, the two
// commits of fork PR #91: red c59eb2db0, fix b37a94dfe): a frame drawn before
// the surface's first cell build runs no cell pass and has a 0 x 0 grid
// (Contents.framePlan), so a new surface shows its plain background, never
// cells of another buffer. No C API change.
//
// A pin change is one reviewed commit that changes the URL and the checksum
// together (the zip's sha256, also in the release's SHA256SUMS). Never pin
// a7c40619a or 3e9dfca98 (apple-v6 without the lib prefix on the macOS
// archive), ios-v1 (module GhosttyKit) or ios-v2 (draws black).
let package = Package(
    name: "CmuxGhosttyKit",
    products: [
        .library(
            name: "CmuxGhosttyKit",
            targets: ["GhosttyNextKit", "CmuxGhosttyKitLink"]
        ),
    ],
    targets: [
        // libghostty-internal.a carries C++ (glslang): every consumer of the
        // product links libc++ through this target (Xcode 27's per-target
        // test bundles failed without it).
        .target(
            name: "CmuxGhosttyKitLink",
            dependencies: ["GhosttyNextKit"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .binaryTarget(
            name: "GhosttyNextKit",
            url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-b37a94dfec401407047f34ecfbc5151be6566a56-apple-v6/GhosttyNextKit.xcframework.zip",
            checksum: "d5085be1f0af3145bbb45e7b9d5dbdeeab13693ef954a9d00d04c984714814ed"
        ),
    ]
)
