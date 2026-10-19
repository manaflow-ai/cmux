// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxTerminalSharing",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxTerminalSharing", targets: ["CmuxTerminalSharing"])],
    dependencies: [.package(path: "../../Shared/CmuxTerminalSizing")],
    targets: [
        .target(name: "CmuxTerminalSharing", dependencies: ["CmuxTerminalSizing"]),
        .testTarget(name: "CmuxTerminalSharingTests", dependencies: ["CmuxTerminalSharing", "CmuxTerminalSizing"]),
    ],
    swiftLanguageModes: [.v6]
)
