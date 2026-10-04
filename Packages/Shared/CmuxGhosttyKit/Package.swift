// swift-tools-version: 6.0

import PackageDescription

// The one libghostty binary for cmux-next: GhosttyNextKit from
// manaflow-ai/ghostty-next (plans/cmux-next/ghostty-next-switch.md). The Mac
// app (CmuxNextTerminal) and the iOS app (CmuxiOSTerminal) both depend on
// this product, so the workspace resolves exactly one binary target of that
// name. Flavor apple-v6: macOS arm64 + x86_64, iOS, iOS simulator. Since
// 59a70ffc6 the iOS keycode in ghostty_input_key_s is the USB HID usage
// (UIKey.keyCode); macOS keeps Mac virtual keycodes.
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
            targets: ["GhosttyNextKit"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyNextKit",
            url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-59a70ffc6858d2a38ba431cebf435a9e73b0b768-apple-v6/GhosttyNextKit.xcframework.zip",
            checksum: "502bea5df20ecca9f03304cb1689fd8e4cd1dd2d5301265907b46889d54013db"
        ),
    ]
)
