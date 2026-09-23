// swift-tools-version: 6.0
import PackageDescription

// Deliberately dependency-free and platform-neutral: the prediction policy is
// the whole correctness story, so it runs on the Linux CI runner rather than
// waiting for a macOS slot.
let package = Package(
    name: "CmuxTerminalPrediction",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CmuxTerminalPrediction", targets: ["CmuxTerminalPrediction"])],
    targets: [
        .target(
            name: "CmuxTerminalPrediction",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxTerminalPredictionTests",
            dependencies: ["CmuxTerminalPrediction"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
