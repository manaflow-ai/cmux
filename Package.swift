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
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        .package(url: "https://github.com/royalapplications/royalvnc.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "cmux",
            dependencies: [
                "SwiftTerm",
                .product(name: "RoyalVNCKit", package: "royalvnc")
            ],
            path: "Sources"
        )
    ]
)
