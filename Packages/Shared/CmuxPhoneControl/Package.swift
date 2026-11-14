// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxPhoneControl",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxPhoneControl",
            targets: ["CmuxPhoneControl"]
        ),
        .executable(
            name: "cmux-phone",
            targets: ["cmux-phone"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxPhoneControl",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "cmux-phone",
            dependencies: ["CmuxPhoneControl"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxPhoneControlTests",
            dependencies: ["CmuxPhoneControl"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
