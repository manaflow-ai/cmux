// swift-tools-version: 6.0

import PackageDescription

// How much the host may feed a chat page that does not drain (cmux NEXT agent pane): the pushes it
// has not acked, when the host stops pushing and holds the stream, which daemon frames the held
// stream may drop (never a prompt or a permission ask), and the one `_acpmux/lagged` the page gets
// once it drains again. Standard library only, so its tests run on Linux; CmuxNextAgentPane's
// transport and socket make their decisions with it.
let package = Package(
    name: "CmuxPagePushBound",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxPagePushBound", targets: ["CmuxPagePushBound"]),
    ],
    targets: [
        .target(
            name: "CmuxPagePushBound",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxPagePushBoundTests",
            dependencies: ["CmuxPagePushBound"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
