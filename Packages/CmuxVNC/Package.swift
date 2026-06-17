// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxVNC",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxVNC",
            targets: ["CmuxVNC"]
        ),
    ],
    dependencies: [
        // Modular exponentiation for Apple Diffie-Hellman (VNC security type 30).
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
    ],
    targets: [
        .target(
            name: "CmuxVNC",
            dependencies: [
                .product(name: "BigInt", package: "BigInt"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CmuxVNCTests",
            dependencies: ["CmuxVNC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
