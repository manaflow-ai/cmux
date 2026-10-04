// swift-tools-version: 6.2

import PackageDescription

// The MessagesLabAppKitNative transcript, vendored (not rewritten) for the
// cmux-next Mac Home tab. Source: MessagesLab (~/fun/messageslab), commit
// 3a53206 ("R76 header"). `vendor.tsv` maps every vendored file to its
// upstream path; `scripts/cmux-next/check-messageslab-vendor.sh` prints the
// difference from upstream (only the blocker edits listed there).
//
// Sources/MessagesLabHome/Vendor holds the upstream files: the catalyst core
// that appkit-native compiles by path (model, reducer, layout, transcript,
// recycler, row drawing, springs, morph, shapes, fixture, header, window view,
// replay), appkit-port's UIKit shim, the appkit-native AppKit parts (compose,
// materials, native scroll, header backdrop, header bar, accessibility and
// selection, host), and the differential harness. Sources/MessagesLabHome/Cmux
// is cmux's glue in the same module (the upstream code has no access
// modifiers): the HomeStore adapter, the pane-hosted view, the in-pane header
// and the theme mapping.
//
// Upstream builds with Swift 5 and minimal strict concurrency
// (appkit-native/project.yml) and the APPKIT_NATIVE condition; this target
// keeps both so the files compile unchanged.
let package = Package(
    name: "CmuxMessagesLab",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "MessagesLabHome", targets: ["MessagesLabHome"]),
    ],
    dependencies: [
        .package(path: "../CmuxHomeCore"),
        .package(path: "../CmuxHomeRender"),
    ],
    targets: [
        .target(
            name: "MessagesLabHome",
            dependencies: [
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
            ],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .process("Resources/AppKitNative.xcstrings"),
                .copy("Resources/springs.json"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
        .testTarget(
            name: "MessagesLabHomeTests",
            dependencies: [
                "MessagesLabHome",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
            ],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
    ]
)
