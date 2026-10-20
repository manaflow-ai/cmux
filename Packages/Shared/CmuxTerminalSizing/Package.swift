// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxTerminalSizing",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CmuxTerminalSizing", targets: ["CmuxTerminalSizing"])],
    targets: [
        .target(name: "CmuxTerminalSizing"),
        .testTarget(name: "CmuxTerminalSizingTests", dependencies: ["CmuxTerminalSizing"])
    ],
    swiftLanguageModes: [.v6]
)
