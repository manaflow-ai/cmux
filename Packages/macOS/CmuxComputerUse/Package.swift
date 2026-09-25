// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxComputerUse",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CmuxComputerUse", targets: ["CmuxComputerUse"])],
    dependencies: [
        .package(path: "../CmuxControlSocket"),
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxSettings")
    ],
    targets: [
        .target(
            name: "CmuxComputerUse",
            dependencies: ["CmuxControlSocket", "CmuxFoundation", "CmuxSettings"],
            // Lane A preserves the executable target's language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "CmuxComputerUseTests", dependencies: ["CmuxComputerUse"])
    ]
)
