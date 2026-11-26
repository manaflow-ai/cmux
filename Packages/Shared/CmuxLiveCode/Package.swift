// swift-tools-version: 6.0

import PackageDescription

// Live code (docs/cmux-next/live-code.md): a running app takes new code for its Swift functions
// without a rebuild or a relaunch. A patch (scripts/live-code/patch.py) dropped into the live folder
// is loaded, every function it defines that the app also defines is repointed to it, and the app
// redraws. The engine is platform-neutral: the macOS app (CmuxNextLiveCode) and the iPhone app in the
// iOS Simulator (cmux-next-ios, CmuxLiveCodeView) each add only their redraw.
let package = Package(
    name: "CmuxLiveCode",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxLiveCode", targets: ["CmuxLiveCode"]),
    ],
    targets: [
        .target(
            name: "CmuxLiveCode",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxLiveCodeTests",
            dependencies: ["CmuxLiveCode"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
