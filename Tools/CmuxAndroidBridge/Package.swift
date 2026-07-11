// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CmuxAndroidBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmux-android-bridge", targets: ["CmuxAndroidBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.2"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .executableTarget(
            name: "CmuxAndroidBridge",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CmuxAndroidBridgeTests",
            dependencies: ["CmuxAndroidBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
