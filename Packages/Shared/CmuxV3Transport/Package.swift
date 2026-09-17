// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxV3Transport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxV3Transport", targets: ["CmuxV3Transport"])],
    dependencies: [.package(path: "../CMUXMobileCore")],
    targets: [
        .binaryTarget(name: "CmuxV3NativeFFI", path: "Native/CmuxV3NativeFFI.xcframework"),
        .target(name: "CmuxV3Native", dependencies: ["CmuxV3NativeFFI"],
                linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration"), .linkedLibrary("resolv")]),
        .target(name: "CmuxV3Transport", dependencies: ["CmuxV3Native", "CMUXMobileCore"]),
        .testTarget(name: "CmuxV3TransportTests", dependencies: ["CmuxV3Transport", "CmuxV3Native", "CMUXMobileCore"]),
    ],
    swiftLanguageModes: [.v6]
)
