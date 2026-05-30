// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CmuxTerminalAccess",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CmuxTerminalAccess", targets: ["CmuxTerminalAccess"]),
    ],
    targets: [
        .target(
            name: "CmuxTerminalAccess",
            path: "Sources/CmuxTerminalAccess"
        ),
        .testTarget(
            name: "CmuxTerminalAccessTests",
            dependencies: ["CmuxTerminalAccess"],
            path: "Tests/CmuxTerminalAccessTests"
        ),
    ]
)
