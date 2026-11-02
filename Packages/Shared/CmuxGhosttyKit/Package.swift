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
            url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-34e73ba8ba7cb8da0115caeb780065e3a12f2f62-apple-v6/GhosttyNextKit.xcframework.zip",
            checksum: "32cb09bbc69510a099df9206a460cc8e7f2aba41a1a5489de98f185da07154a4"
        ),
    ]
)
