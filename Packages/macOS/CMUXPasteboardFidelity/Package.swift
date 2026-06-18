// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXPasteboardFidelity",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXPasteboardFidelity",
            targets: ["CMUXPasteboardFidelity"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXPasteboardFidelity"
        ),
        .testTarget(
            name: "CMUXPasteboardFidelityTests",
            dependencies: ["CMUXPasteboardFidelity"]
        ),
    ]
)
