// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxProjectIdentity",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxProjectIdentity", targets: ["CmuxProjectIdentity"]),
    ],
    targets: [
        .target(
            name: "CmuxProjectIdentity",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxProjectIdentityTests",
            dependencies: ["CmuxProjectIdentity"]
        ),
    ]
)
