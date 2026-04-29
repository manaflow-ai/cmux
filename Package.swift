// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cmux",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "cmux", targets: ["cmux"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "cmux",
            dependencies: [],
            path: "Sources"
        )
    ]
)
