// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CMUXDesktopPrototype",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "CMUXDesktopPrototype", targets: ["CMUXDesktopPrototype"]),
    ],
    targets: [
        .executableTarget(
            name: "CMUXDesktopPrototype",
            path: "Sources/CMUXDesktopPrototype",
            resources: [.process("Resources")]
        ),
    ]
)
