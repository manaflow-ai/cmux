// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SettingsShellLab",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "SettingsShellLab", targets: ["SettingsShellLab"]),
    ],
    targets: [
        .executableTarget(
            name: "SettingsShellLab",
            path: "Sources/SettingsShellLab",
            resources: [.process("Resources")]
        ),
    ]
)
