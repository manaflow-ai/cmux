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
            url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-48d353b8c3a6518c11cfd1e0ad1bbd3e75d725a2-apple-v6/GhosttyNextKit.xcframework.zip",
            checksum: "a01bc971185d86e72f6fe882090607c49323d10c7699fc492bea0835f7cec56d"
        ),
    ]
)
