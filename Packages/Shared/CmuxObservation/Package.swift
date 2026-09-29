// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxObservation",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CmuxObservation", targets: ["CmuxObservation"])],
    targets: [
        .target(name: "CmuxObservation"),
        .testTarget(name: "CmuxObservationTests", dependencies: ["CmuxObservation"])
    ],
    swiftLanguageModes: [.v6]
)
