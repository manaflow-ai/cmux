// swift-tools-version: 6.2

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
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
